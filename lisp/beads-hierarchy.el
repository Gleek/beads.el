;;; beads-hierarchy.el --- Dependency tree view for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tree view for visualizing issue dependencies using hierarchy.el.

;;; Code:

(require 'hierarchy)
(require 'wid-edit)
(require 'tree-widget)
(require 'beads-client)
(require 'beads-faces)

(declare-function beads-detail-open "beads-detail")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-make-overriding-map "evil-core")

(defgroup beads-hierarchy nil
  "Dependency tree display for Beads."
  :group 'beads)

(defvar-local beads-hierarchy--root-id nil
  "Root issue ID for current hierarchy buffer.")

(defvar-local beads-hierarchy--hierarchy nil
  "The hierarchy object for current buffer.")

(defvar-local beads-hierarchy--by-id nil
  "Hash table mapping issue IDs to issue data.")

(defvar-local beads-hierarchy--refresh-process nil
  "Pending issue-list request for this hierarchy buffer.")

(defvar-local beads-hierarchy--refresh-token nil
  "Identity of the current refresh, used to ignore obsolete results.")

(defun beads-hierarchy--cancel-refresh ()
  "Cancel any pending hierarchy refresh."
  (setq beads-hierarchy--refresh-token nil)
  (beads-backend-cancel beads-hierarchy--refresh-process)
  (setq beads-hierarchy--refresh-process nil))

(defvar beads-hierarchy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'beads-hierarchy-refresh)
    (define-key map (kbd "RET") #'beads-hierarchy-goto-issue)
    (define-key map (kbd "TAB") #'beads-hierarchy-next)
    (define-key map (kbd "<backtab>") #'beads-hierarchy-previous)
    map)
  "Keymap for beads-hierarchy-mode.")

(defun beads-hierarchy--collect-positions ()
  "Collect positions of all interactable elements in buffer.
Returns sorted list of positions for widgets and buttons."
  (let ((positions nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (widget-at (point))
          (push (point) positions))
        (forward-char 1)))
    (save-excursion
      (goto-char (point-min))
      (let ((button (next-button (point))))
        (while button
          (push (button-start button) positions)
          (setq button (next-button (button-end button))))))
    (sort (delete-dups positions) #'<)))

(defun beads-hierarchy-next ()
  "Move to next interactable element (widget or button)."
  (interactive)
  (let* ((positions (beads-hierarchy--collect-positions))
         (pos (point))
         (next (seq-find (lambda (p) (> p pos)) positions)))
    (if next
        (goto-char next)
      (when positions
        (goto-char (car positions))))))

(defun beads-hierarchy-previous ()
  "Move to previous interactable element (widget or button)."
  (interactive)
  (let* ((positions (beads-hierarchy--collect-positions))
         (pos (point))
         (prev (seq-find (lambda (p) (< p pos)) (reverse positions))))
    (if prev
        (goto-char prev)
      (when positions
        (goto-char (car (last positions)))))))

(define-derived-mode beads-hierarchy-mode special-mode "Beads-Deps"
  "Major mode for displaying issue dependency trees.

\\{beads-hierarchy-mode-map}"
  (add-hook 'kill-buffer-hook #'beads-hierarchy--cancel-refresh nil t)
  (add-hook 'change-major-mode-hook #'beads-hierarchy--cancel-refresh nil t))

;; Configure evil-mode IF user has it loaded (does not enable evil)
(with-eval-after-load 'evil
  (evil-set-initial-state 'beads-hierarchy-mode 'normal)
  (evil-make-overriding-map beads-hierarchy-mode-map 'normal))

(defun beads-hierarchy--labelfn (issue indent)
  "Insert formatted ISSUE at INDENT level.
Format: ID [type] title [status]"
  (let* ((id (alist-get 'id issue))
         (title (alist-get 'title issue ""))
         (type-str (beads--format-type issue))
         (status-str (beads--format-status issue))
         (tree-indent (* indent 3))
         (fixed-width (+ (length id) (length type-str) (length status-str) 8))
         (available (- (window-body-width) tree-indent fixed-width)))
    (insert " ")
    (insert-text-button id
                        'face 'beads-detail-id-face
                        'action #'beads-hierarchy--button-action
                        'beads-issue issue
                        'follow-link t)
    (insert " ")
    (insert type-str)
    (insert " ")
    (insert (truncate-string-to-width title (max 10 available) nil nil "…"))
    (insert " [")
    (insert status-str)
    (insert "]")))

(defun beads-hierarchy--button-action (button)
  "Handle activation of issue BUTTON."
  (let ((issue (button-get button 'beads-issue)))
    (when issue
      (condition-case err
          (let* ((id (alist-get 'id issue))
                 (full-issue (beads-client-show id)))
            (beads-detail-open full-issue))
        (beads-client-error
         (message "Failed to fetch issue: %s" (error-message-string err)))))))

(defun beads-hierarchy--build (issue-id issues)
  "Build ISSUE-ID's ancestor and descendant tree from ISSUES.
Return (hierarchy . by-id-hash).  Visit each issue once, including when
relationships contain cycles or shared dependencies."
  (let ((all (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal))
        (children (make-hash-table :test 'equal))
        (tree-parents (make-hash-table :test 'equal))
        (by-id (make-hash-table :test 'equal))
        (h (hierarchy-new)))
    (seq-doseq (issue issues)
      (let ((id (alist-get 'id issue)))
        (puthash id issue all)
        (dolist (parent
                 (delete-dups
                  (delq nil
                        (cons (beads-client-issue-parent issue)
                              (mapcar (lambda (dep)
                                        (or (alist-get 'depends_on_id dep)
                                            (alist-get 'id dep)))
                                      (append (alist-get 'dependencies issue) nil))))))
          (push parent (gethash id parents))
          (push id (gethash parent children)))))
    (unless (gethash issue-id all)
      (signal 'beads-client-error (list (format "Issue not found: %s" issue-id))))
    (puthash issue-id (gethash issue-id all) by-id)
    (cl-labels
        ((collect (links ancestors)
           (let ((pending (list issue-id)))
             (while pending
               (let ((id (pop pending)))
                 (dolist (next (gethash id links))
                   (when (and (gethash next all) (not (gethash next by-id)))
                     (puthash next (gethash next all) by-id)
                     (if ancestors
                         (unless (gethash id tree-parents)
                           (puthash id next tree-parents))
                       (puthash next id tree-parents))
                     (push next pending))))))))
      (collect parents t)
      (collect children nil))
    (maphash (lambda (_id issue)
               (hierarchy-add-tree
                h issue (lambda (item)
                          (gethash (gethash (alist-get 'id item) tree-parents) by-id))))
             by-id)
    (cons h by-id)))

(defun beads-hierarchy-goto-issue ()
  "Open detail view for issue at point."
  (interactive)
  (let ((issue nil))
    (when-let ((widget (widget-at (point))))
      (setq issue (widget-get widget :node)))
    (unless issue
      (when beads-hierarchy--by-id
        (save-excursion
          (beginning-of-line)
          (when (re-search-forward "\\([a-z]+-[a-z0-9]+\\)" (line-end-position) t)
            (let ((id (match-string 1)))
              (setq issue (gethash id beads-hierarchy--by-id)))))))
    (if issue
        (condition-case err
            (let* ((id (alist-get 'id issue))
                   (full-issue (beads-client-show id)))
              (beads-detail-open full-issue))
          (beads-client-error
           (message "Failed to fetch issue: %s" (error-message-string err))))
      (message "No issue at point"))))

(defun beads-hierarchy--goto-issue (issue-id)
  "Move point to ISSUE-ID in the hierarchy buffer."
  (goto-char (point-min))
  (when (re-search-forward (regexp-quote issue-id) nil t)
    (goto-char (match-beginning 0))))

(defun beads-hierarchy-refresh ()
  "Refresh the dependency tree display."
  (interactive)
  (unless beads-hierarchy--root-id
    (user-error "No root issue set"))
  (beads-hierarchy-show beads-hierarchy--root-id))

;;;###autoload
(defun beads-hierarchy-show (issue-id)
  "Display dependency tree for ISSUE-ID in a side window."
  (interactive
   (list (cond
          ((and (boundp 'beads-detail--current-issue-id)
                beads-detail--current-issue-id)
           beads-detail--current-issue-id)
          ((and (derived-mode-p 'beads-list-mode)
                (tabulated-list-get-id))
           (tabulated-list-get-id))
          (t (read-string "Issue ID: ")))))
  (let* ((directory default-directory)
         (buffer (get-buffer-create (format "*Beads Deps: %s*" issue-id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'beads-hierarchy-mode)
        (beads-hierarchy-mode))
      (beads-hierarchy--cancel-refresh)
      (setq default-directory directory
            beads-hierarchy--root-id issue-id)
      (let ((token (setq beads-hierarchy--refresh-token (list 'refresh))))
        (setq beads-hierarchy--refresh-process
              (beads-client-request-async
               "list" nil
               (lambda (issues err)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (eq token beads-hierarchy--refresh-token)
                       (setq beads-hierarchy--refresh-process nil)
                       (if err
                           (message "Failed to fetch dependency tree: %s"
                                    (error-message-string err))
                         (condition-case err
                             (beads-hierarchy--render issue-id issues)
                           (beads-client-error
                            (message "%s" (error-message-string err)))))))))))))
    (let ((window (display-buffer buffer
                                  '((display-buffer-in-side-window)
                                    (side . right)
                                    (window-width . 0.4)))))
      (when window (select-window window)))))

(defun beads-hierarchy--render (issue-id issues)
  "Render ISSUE-ID's tree from ISSUES in the current hierarchy buffer."
  (let* ((saved-point (and beads-hierarchy--hierarchy (point)))
         (window (get-buffer-window (current-buffer)))
         (saved-start (and window (window-start window)))
         (result (beads-hierarchy--build issue-id issues))
         (h (car result))
         (inhibit-read-only t))
    (erase-buffer)
    (dolist (root (hierarchy-roots h))
      (widget-create
       (hierarchy-map-tree
        (lambda (issue indent children)
          (widget-convert 'tree-widget
                          :tag (hierarchy-labelfn-to-string
                                #'beads-hierarchy--labelfn issue indent)
                          :open t :args children))
        h root)))
    (widget-setup)
    (setq beads-hierarchy--root-id issue-id
          beads-hierarchy--hierarchy h
          beads-hierarchy--by-id (cdr result))
    (if saved-point
        (progn
          (goto-char (min saved-point (point-max)))
          (when window (set-window-start window (min saved-start (point-max)))))
      (beads-hierarchy--goto-issue issue-id))))

(provide 'beads-hierarchy)
;;; beads-hierarchy.el ends here
