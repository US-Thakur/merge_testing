;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'org)
(require 'seq)

(require 'dash)

;;;; Variables

(defvar org-ql--today nil)

;;;; Macros

(cl-defmacro org-ql (files pred-body &key (action-fn (lambda (element) (list element))))
  "Find entries in FILES that match PRED-BODY, and return the results of running ACTION-FN on each matching entry.

ACTION-FN should take a single argument, which will be the result
of calling `org-element-headline-parser' at each matching entry."
  (declare (indent defun))
  `(org-ql--query ,files
                  (byte-compile (lambda ()
                                  (cl-symbol-macrolet ((= #'=)
                                                       (< #'<)
                                                       (> #'>)
                                                       (<= #'<=)
                                                       (>= #'>=))
                                    ,pred-body)))
                  #',action-fn))

(defmacro org-ql--fmap (fns &rest body)
  (declare (indent defun))
  `(cl-letf ,(cl-loop for (fn target) in fns
                      collect `((symbol-function ',fn)
                                (symbol-function ,target)))
     ,@body))

;;;; Functions

(cl-defun org-ql--query (files pred action-fn)
  (setq files (cl-typecase files
                (null (list (buffer-file-name (current-buffer))))
                (list files)
                (string (list files))))
  (mapc 'find-file-noselect files)
  (let* ((org-use-tag-inheritance t)
         (org-scanner-tags nil)
         (org-trust-scanner-tags t)
         (org-ql--today (org-today)))
    (-flatten-n 1 (--map (with-current-buffer (find-buffer-visiting it)
                           (mapcar action-fn
                                   (org-ql--filter-buffer :pred pred)))
                         files))))

(cl-defun org-ql--filter-buffer (&key pred)
  "Return positions of matching headings in current buffer.
Headings should return non-nil for any ANY-PREDS and nil for all
NONE-PREDS."
  ;; Cache `org-today' so we don't have to run it repeatedly.
  (cl-letf ((today org-ql--today))
    (org-ql--fmap ((category #'org-ql--category-p)
                   (date #'org-ql--date-plain-p)
                   (deadline #'org-ql--deadline-p)
                   (scheduled #'org-ql--scheduled-p)
                   (closed #'org-ql--closed-p)
                   (habit #'org-ql--habit-p)
                   (priority #'org-ql--priority-p)
                   (todo #'org-ql--todo-p)
                   (done #'org-ql--done-p)
                   (tags #'org-ql--tags-p)
                   (property #'org-ql--property-p)
                   (regexp #'org-ql--regexp-p)
                   (org-back-to-heading #'outline-back-to-heading))
      (org-with-wide-buffer
       (goto-char (point-min))
       (when (org-before-first-heading-p)
         (outline-next-heading))
       (cl-loop when (funcall pred)
                collect (org-element-headline-parser (line-end-position))
                while (outline-next-heading))))))

;;;;; Predicates

(defun org-ql--category-p (&rest categories)
  "Return non-nil if current heading is in one or more of CATEGORIES."
  (when-let ((category (org-get-category (point))))
    (cl-typecase categories
      (null t)
      (otherwise (member category categories)))))

(defun org-ql--todo-p (&rest keywords)
  "Return non-nil if current heading is a TODO item.
With KEYWORDS, return non-nil if its keyword is one of KEYWORDS."
  (when-let ((state (org-get-todo-state)))
    (cl-typecase keywords
      (null t)
      (list (member state keywords))
      (symbol (member state (symbol-value keywords)))
      (otherwise (user-error "Invalid todo keywords: %s" keywords)))))

(defsubst org-ql--done-p ()
  (apply #'org-ql--todo-p org-done-keywords-for-agenda))

(defun org-ql--tags-p (&rest tags)
  "Return non-nil if current heading has TAGS."
  ;; TODO: Try to use `org-make-tags-matcher' to improve performance.
  (when-let ((tags-at (org-get-tags-at (point)
                                       ;; FIXME: Would be nice to not check this for every heading checked.
                                       ;; FIXME: Figure out whether I should use `org-agenda-use-tag-inheritance' or `org-use-tag-inheritance', etc.
                                       ;; (not (member 'agenda org-agenda-use-tag-inheritance))
                                       org-use-tag-inheritance)))
    (cl-typecase tags
      (null t)
      (otherwise (seq-intersection tags tags-at)))))

(defun org-agenda-ng--date-p (type &optional comparator target-date)
  "Return non-nil if current heading has a date property of TYPE.
TYPE should be a keyword symbol, like :scheduled or :deadline.

With COMPARATOR and TARGET-DATE, return non-nil if entry's
scheduled date compares with TARGET-DATE according to COMPARATOR.
TARGET-DATE may be a string like \"2017-08-05\", or an integer
like one returned by `date-to-day'."
  (when-let ((timestamp (pcase type
                          ;; FIXME: Add :date selector, since I put it
                          ;; in the examples but forgot to actually
                          ;; make it.
                          (:deadline (org-entry-get (point) "DEADLINE"))
                          (:scheduled (org-entry-get (point) "SCHEDULED"))
                          (:closed (org-entry-get (point) "CLOSED"))))
             (date-element (with-temp-buffer
                             ;; FIXME: Hack: since we're using
                             ;; (org-element-property :type date-element)
                             ;; below, we need this date parsed into an
                             ;; org-element element
                             (insert timestamp)
                             (goto-char 0)
                             (org-element-timestamp-parser))))
    (pcase comparator
      ;; Not comparing, just checking if it has one
      ('nil t)
      ;; Compare dates
      ((pred functionp)
       (let ((target-day-number (cl-typecase target-date
                                  (null (+ (org-get-wdays timestamp) (org-today)))
                                  ;; Append time to target-date
                                  ;; because `date-to-day' requires it
                                  (string (date-to-day (concat target-date " 00:00")))
                                  (integer target-date))))
         (pcase (org-element-property :type date-element)
           ((or 'active 'inactive)
            (funcall comparator
                     (org-time-string-to-absolute
                      (org-element-timestamp-interpreter date-element 'ignore))
                     target-day-number))
           (error "Unknown date-element type: %s" (org-element-property :type date-element)))))
      (otherwise (error "COMPARATOR (%s) must be a function, and DATE (%s) must be a string" comparator target-date)))))

(defsubst org-ql--date-plain-p (&optional comparator target-date)
  (org-agenda-ng--date-p :date comparator target-date))
(defsubst org-ql--deadline-p (&optional comparator target-date)
  ;; FIXME: This is slightly confusing.  Using plain (deadline) does, and should, select entries
  ;; that have any deadline.  But the common case of wanting to select entries whose deadline is
  ;; within the warning days (either the global setting or that entry's setting) requires the user
  ;; to specify the <= comparator, which is unintuitive.  Maybe it would be better to use that
  ;; comparator by default, and use an 'any comparator to select entries with any deadline.  Of
  ;; course, that would make the deadline selector different from the scheduled, closed, and date
  ;; selectors, which would also be unintuitive.
  (org-agenda-ng--date-p :deadline comparator target-date))
(defsubst org-ql--scheduled-p (&optional comparator target-date)
  (org-agenda-ng--date-p :scheduled comparator target-date))
(defsubst org-ql--closed-p (&optional comparator target-date)
  (org-agenda-ng--date-p :closed comparator target-date))

(defun org-ql--priority-p (&optional comparator-or-priority priority)
  "Return non-nil if current heading has a certain priority.
COMPARATOR-OR-PRIORITY should be either a comparator function,
like `<=', or a priority string, like \"A\" (in which case (\` =)
'will be the comparator).  If COMPARATOR-OR-PRIORITY is a
comparator, PRIORITY should be a priority string."
  (let* (comparator)
    (cond ((null priority)
           ;; No comparator given: compare only given priority with =
           (setq priority comparator-or-priority
                 comparator '=))
          (t
           ;; Both comparator and priority given
           (setq comparator comparator-or-priority)))
    (setq comparator (cl-case comparator
                       ;; Invert comparator because higher priority means lower number
                       (< '>)
                       (> '<)
                       (<= '>=)
                       (>= '<=)
                       (= '=)
                       (otherwise (user-error "Invalid comparator: %s" comparator))))
    (setq priority (* 1000 (- org-lowest-priority (string-to-char priority))))
    (when-let ((item-priority (save-excursion
                                (save-match-data
                                  ;; FIXME: Is the save-match-data above necessary?
                                  (when (and (looking-at org-heading-regexp)
                                             (save-match-data
                                               (string-match org-priority-regexp (match-string 0))))
                                    ;; TODO: Items with no priority
                                    ;; should not be the same as B
                                    ;; priority.  That's not very
                                    ;; useful IMO.  Better to do it
                                    ;; like in org-super-agenda.
                                    (org-get-priority (match-string 0)))))))
      (funcall comparator priority item-priority))))

(defun org-ql--habit-p ()
  (org-is-habit-p))

(defun org-ql--regexp-p (regexp)
  "Return non-nil if current entry matches REGEXP."
  (let ((end (or (save-excursion
                   (outline-next-heading))
                 (point-max))))
    (save-excursion
      (goto-char (line-beginning-position))
      (re-search-forward regexp end t))))

(defun org-ql--property-p (property &optional value)
  "Return non-nil if current entry has PROPERTY, and optionally VALUE."
  (pcase property
    ('nil (user-error "Property matcher requires a PROPERTY argument."))
    (_ (pcase value
         ('nil
          ;; Check that PROPERTY exists
          (org-entry-get (point) property))
         (_
          ;; Check that PROPERTY has VALUE
          (string-equal value (org-entry-get (point) property 'selective)))))))

(provide 'org-ql)
