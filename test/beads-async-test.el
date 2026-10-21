;;; beads-async-test.el --- Async refresh regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'beads)

(defun beads-async-test--wait (predicate)
  "Process events until PREDICATE succeeds, failing after five seconds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(ert-deftest beads-async-test-transport ()
  "Processes return immediately, keep stderr separate, and normalize results."
  (let (done result failure tick stdout stderr)
    (cl-letf (((symbol-function 'beads-backend--cli-command)
               (lambda (&rest _)
                 '("sh" "-c" "sleep 0.15; echo diagnostic >&2; printf '{\"summary\":{\"total_issues\":7}}'"))))
      (let* ((proc (beads-client-request-async
                    "stats" nil
                    (lambda (data err) (setq done t result data failure err))))
             (timer (run-at-time 0.01 nil (lambda () (setq tick t)))))
        (setq stdout (process-buffer proc)
              stderr (process-buffer (get-buffer-process " *beads-stderr*")))
        (unwind-protect
            (progn
              (should (process-live-p proc))
              (should-not done)
              (beads-async-test--wait (lambda () done))
              (should tick)
              (should-not failure)
              (should (= 7 (alist-get 'total_issues result)))
              (should-not (buffer-live-p stdout))
              (should-not (buffer-live-p stderr)))
          (cancel-timer timer)
          (beads-backend-cancel proc))))))

(ert-deftest beads-async-test-failures ()
  "Nonzero exit, malformed JSON and launch errors reach the error callback."
  (dolist (command '(("sh" "-c" "echo missing-database >&2; exit 1")
                     ("sh" "-c" "echo invalid-json")
                     ("/nonexistent/beads-test-program")))
    (let (done failure)
      (cl-letf (((symbol-function 'beads-backend--cli-command)
                 (lambda (&rest _) command)))
        (beads-client-request-async
         "list" nil (lambda (_data err) (setq done t failure err)))
        (beads-async-test--wait (lambda () done))
        (should (eq (car failure) 'beads-client-error))))))

(ert-deftest beads-async-test-project-context ()
  "The child receives its launch directory and environment after buffer switches."
  (let ((default-directory temporary-file-directory)
        (process-environment (copy-sequence process-environment))
        done result)
    (setenv "BEADS_ASYNC_TEST" "origin")
    (cl-letf (((symbol-function 'beads-backend--cli-command)
               (lambda (&rest _)
                 '("sh" "-c" "sleep 0.05; printf '{\"directory\":\"%s\",\"env\":\"%s\"}' \"$PWD\" \"$BEADS_ASYNC_TEST\""))))
      (beads-client-request-async
       "show" nil
       (lambda (data err) (should-not err) (setq done t result data))))
    (let ((default-directory "/")
          (process-environment (copy-sequence process-environment)))
      (setenv "BEADS_ASYNC_TEST" "elsewhere")
      (beads-async-test--wait (lambda () done)))
    (should (equal (file-truename default-directory)
                   (file-truename (file-name-as-directory (alist-get 'directory result)))))
    (should (equal "origin" (alist-get 'env result)))))

(defconst beads-async-test--issues
  '(((id . "test-1") (title . "First") (status . "open") (priority . 2)
     (issue_type . "task") (created_at . "2026-10-21T00:00:00Z"))
    ((id . "test-2") (title . "Second") (status . "open") (priority . 1)
     (issue_type . "bug") (created_at . "2026-10-21T00:00:00Z"))))

(ert-deftest beads-async-test-refresh-superseded-and-killed ()
  "Old callbacks cannot replace newer rows or update killed buffers."
  (let ((beads-autoupdate-enable nil) (beads-verbose nil)
        (beads-list-show-header-stats nil) callbacks)
    (cl-letf (((symbol-function 'beads-client-request-async)
               (lambda (_op _args callback) (push callback callbacks) nil)))
      (let ((buffer (generate-new-buffer " *beads-async*")))
        (unwind-protect
            (with-current-buffer buffer
              (beads-list-mode)
              (beads-list--render beads-async-test--issues nil t)
              (setq beads-list--marked '("test-2"))
              (beads-list-refresh t)
              (beads-list-refresh t)
              (should (= 2 (length beads-list--issues)))
              (beads-list-goto-id "test-2")
              (with-temp-buffer
                (funcall (car callbacks) beads-async-test--issues nil))
              (should (equal "test-2" (tabulated-list-get-id)))
              (should (equal '("test-2") beads-list--marked))
              (should (= 2 (length beads-list--issues)))
              (funcall (cadr callbacks) nil nil)
              (should (= 2 (length beads-list--issues)))
              (beads-list-refresh t)
              (kill-buffer buffer)
              (funcall (car callbacks) beads-async-test--issues nil))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest beads-async-test-ready-and-stats ()
  "Composed readiness and stats never fall back to synchronous CLI calls."
  (let ((beads-autoupdate-enable nil) (beads-verbose nil)
        (beads-list-show-header-stats t) requests)
    (with-temp-buffer
      (beads-list-mode)
      (setq beads-list--filter
            (beads-filter-negate
             (beads-filter-compose-or (beads-filter-ready)
                                      (beads-filter-by-status "closed"))))
      (cl-letf (((symbol-function 'beads-client-request-async)
                 (lambda (op args callback) (push (list op args callback) requests) nil))
                ((symbol-function 'beads-client-ready)
                 (lambda (&rest _) (ert-fail "Blocking ready call")))
                ((symbol-function 'beads-client-stats)
                 (lambda (&rest _) (ert-fail "Blocking stats call"))))
        (beads-list-refresh t)
        (funcall (nth 2 (car requests)) beads-async-test--issues nil)
        (should (equal "ready" (caar requests)))
        (should (equal '((limit . 0)) (nth 1 (car requests))))
        ;; Empty readiness must remain an empty set, not trigger a sync lookup.
        (funcall (nth 2 (car requests)) nil nil)
        (should (= 2 (length beads-list--issues)))
        (should (equal "stats" (caar requests)))
        (funcall (nth 2 (car requests)) '((total_issues . 2)) nil)
        (should (string-match-p "2 total" header-line-format))))))

(ert-deftest beads-async-test-cancel-on-mode-change ()
  "Changing modes terminates the child and frees its output buffers."
  (let ((beads-autoupdate-enable nil) (beads-verbose nil) proc stdout called)
    (with-temp-buffer
      (beads-list-mode)
      (cl-letf (((symbol-function 'beads-backend--cli-command)
                 (lambda (&rest _) '("sh" "-c" "sleep 0.2; echo '[]'"))))
        (beads-list--fetch
         (setq beads-list--refresh-token '(refresh)) "list" nil
         (lambda (&rest _) (setq called t)))
        (setq proc beads-list--refresh-process stdout (process-buffer proc))
        (fundamental-mode)
        (beads-async-test--wait (lambda () (not (buffer-live-p stdout))))
        (should-not (process-live-p proc))
        (should-not called)))))

(provide 'beads-async-test)
;;; beads-async-test.el ends here
