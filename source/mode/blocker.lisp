;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(uiop:define-package :nyxt/blocker-mode
  (:use :common-lisp :nyxt)
  (:import-from #:class-star #:define-class)
  (:documentation "Block resource queries for listed hosts."))
(in-package :nyxt/blocker-mode)
(use-nyxt-package-nicknames)

;; TODO: Add convenient interface to block hosts depending on the current URL.

(defclass hostlist-data-path (data-path) ())

(define-class hostlist ()
  ((url
    (quri:uri "")
    :type quri:uri
    :documentation "URL where to download the list from.  If empty, no attempt
will be made at updating it.")
   (path
    (make-instance 'hostlist-data-path)
    :type hostlist-data-path
    :documentation "Where to find the list locally.
If nil, the list won't be persisted.
If path is relative, it will be set to (xdg-data-home path).")
   (hosts
    '()
    :documentation "Deprecated, see `load-hostlist' and `blocked-hosts' instead.")
   (update-interval
    (* 60 60 24)
    :type integer
    :documentation "If URL is provided, update the list after this amount of
seconds."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (class*:make-name-transformer name))
  (:documentation "A hostlist `blocker-mode' can use for its `hostlists' slot.
See `*default-hostlist*' for an example."))

(serapeum:export-always 'make-hostlist)
(defun make-hostlist (&rest args)
  "Return a new `hostlist'.
See the `hostlist' class documentation."
  (apply #'make-instance 'hostlist args))

(defmethod update ((hostlist hostlist) mode)
  "Fetch HOSTLIST and return it.
If HOSTLIST has a `path', persist it locally."
  (unless (uiop:emptyp (url hostlist))
    (let ((path (expand-path (path hostlist)))
          (url-string (render-url (url hostlist))))
      (log:info "Updating hostlist ~s from ~s." path
                url-string)
      (handler-case
          (let ((hosts (dex:get url-string)))
            (when (and hosts path)
              (load-hostlist hosts mode)
              (handler-case
                  (alex:write-string-into-file hosts (ensure-parent-exists path)
                                               :if-exists :supersede
                                               :if-does-not-exist :create)
                (error (c)
                  (log:error "Could not persist hostlist ~s: ~a" path c))))
            hosts)
        (t (c)
          (log:error "Could not download hostlist ~a: ~a" url-string c))))))

(defvar *update-lock* (bt:make-lock))

(defmethod update-hostlist-with-lock ((hostlist hostlist) mode)
  (run-thread "blocker-mode hostlist updater"
    (when (bt:acquire-lock *update-lock* nil)
       (update hostlist mode)
       (bt:release-lock *update-lock*))))

(defmethod read-hostlist ((hostlist hostlist) mode)
  "Return hostlist file as a string.
Return nil if hostlist file is not ready yet.
Auto-update file if older than UPDATE-INTERVAL seconds.

The hostlist is downloaded in the background.
The new hostlist will be used as soon as it is available."
  (when (or (not (uiop:file-exists-p (expand-path (path hostlist))))
            (< (update-interval hostlist)
               (- (get-universal-time) (uiop:safe-file-write-date (expand-path (path hostlist))))))
    (update-hostlist-with-lock hostlist mode))
  (handler-case
      (uiop:read-file-string (expand-path (path hostlist)))
    (error ()
      (log:warn "Hostlist not found: ~a" (expand-path (path hostlist)))
      nil)))

(defmethod load-hostlist ((hostlist-string string) mode)
  "Load HOSTLIST-STRING into MODE's `blocked-hosts'."
  (unless (uiop:emptyp hostlist-string)
    (with-input-from-string (stream hostlist-string)
      (flet ((empty-line? (line)
               (< (length line) 2))
             (comment? (line)
               (string= (subseq line 0 1) "#"))
             (custom-hosts? (line)
               (not (str:starts-with? "0.0.0.0" line))))
        (loop as line = (read-line stream nil)
              while line
              unless (or (empty-line? line)
                         (comment? line)
                         (custom-hosts? line))
                do (let ((host (second (str:split " " line))))
                     (setf (gethash host (blocked-hosts mode)) host)))))))

(defmethod load-hostlist ((hostlist hostlist) mode)
  "Load HOSTLIST into MODE's `blocked-hosts'."
  (let ((hostlist-string (read-hostlist hostlist mode)))
    (load-hostlist hostlist-string mode)))

(serapeum:export-always '*default-hostlist*)
(defparameter *default-hostlist*
  (make-instance 'hostlist
                 :url (quri:uri "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")
                 :path (make-instance 'hostlist-data-path :basename "hostlist-stevenblack.txt"))
  "Default hostlist for `blocker-mode'.")

(define-mode blocker-mode ()
  "Enable blocking of listed hosts.
To customize the list of blocked hosts, set the `hostlists' slot.
See the `hostlist' class documentation.

Example:

\(defvar *my-blocked-hosts*
  (nyxt/blocker-mode:make-hostlist
   :hosts '(\"platform.twitter.com\"
            \"syndication.twitter.com\"
            \"m.media-amazon.com\")))

\(define-mode my-blocker-mode (nyxt/blocker-mode:blocker-mode)
  \"Blocker mode with custom hosts from `*my-blocked-hosts*'.\"
  ((nyxt/blocker-mode:hostlists (list *my-blocked-hosts* nyxt/blocker-mode:*default-hostlist*))))

\(define-configuration buffer
  ((default-modes (append '(my-blocker-mode) %slot-default%))))"
  ((hostlists (list *default-hostlist*))
   (blocked-hosts
    (make-hash-table :test 'equal)
    :documentation "The set of domain names to block.")
   (destructor
    (lambda (mode)
      (when (web-buffer-p (buffer mode))
        (hooks:remove-hook (request-resource-hook (buffer mode))
                           'request-resource-block))))
   (constructor
    (lambda (mode)
      (mapc (alex:curry #'load-hostlist mode) (hostlists mode))
      (when (web-buffer-p (buffer mode))
        (if (request-resource-hook (buffer mode))
            (hooks:add-hook (request-resource-hook (buffer mode))
                            (make-handler-resource #'request-resource-block))
            (make-hook-resource
             :combination #'combine-composed-hook-until-nil
             :handlers (list #'request-resource-block))))))))

(defmethod blocklisted-host-p ((mode blocker-mode) host)
  "Return non-nil of HOST if found in the hostlists of MODE.
Return nil if MODE's hostlist cannot be parsed."
  (gethash host (blocked-hosts mode)))

(defun request-resource-block (request-data)
  "Block resource queries from blocklisted hosts.
This is an acceptable handler for `request-resource-hook'."
  (let ((mode (find-submode (buffer request-data) 'blocker-mode)))
    (if (and mode
             (blocklisted-host-p
              mode
              (quri:uri-host (url request-data))))
        (progn
          (log:debug "Dropping ~a for ~a (~a)"
                     (render-url (url request-data))
                     (buffer request-data)
                     (render-url (url (buffer request-data))))
          nil)
        ;; Pass request to the other handlers.
        request-data)))

(defmethod s-serialization:serializable-slots ((object blocker-mode))
  "Discard hostlists which can get pretty big."
  (delete 'nyxt/blocker-mode::hostlists
          (mapcar #'closer-mop:slot-definition-name
                  (closer-mop:class-slots (class-of object)))))

(define-command update-hostlists (&optional (blocker-mode (find-mode (current-buffer) 'blocker-mode)))
  "Forces update for all the hostlists of `blocker-mode'."
  (mapc (alex:rcurry #'update-hostlist-with-lock blocker-mode) (hostlists blocker-mode))
  (echo "Hostlists updated."))
