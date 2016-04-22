;;; es-cc.el --- The Elasticsearch command center

;; Copyright (C) 2016 Matthew Lee Hinman

;; Author: Lee Hinman <lee@writequit.org>
;; URL: http://www.github.com/dakrone/es-mode
;; Version: 1.0.0
;; Keywords: elasticsearch
;; Package-Requires: ((dash "2.11.0") (cl-lib "0.5") (spark "1.0"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Provides a command center for monitoring Elasticsearch clusters

;;; Usage:

;; TODO: document usage

;;; License:

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Code:

(require 'cl-lib)
(require 'spark)
(require 'url)
(require 'url-handlers)
(require 'url-parse)
(require 'url-util)
(require 'dash)

(defgroup es-cc nil
  "Elasticsearch command center"
  :group 'monitoring)

(defcustom es-cc-endpoint "http://localhost:9200/"
  "The endpoint to be monitored"
  :group 'es-cc
  :type 'string)

(defun es-cc-get-nodes-stats-endpoint ()
  (concat es-cc-endpoint "_nodes/stats"))

(defvar es-cc--bounds-for-metric
  "Bounds for spark line for different metric names"
  '(:mem
    (:min 0 :max 100)
    :cpu
    (:min 0 :max 100)
    :load
    (:min 0 :max :auto)))

(defun es-cc--spark-v-for-metric (info-plist metric)
  "Given a `metric' keyword and info, return the spark-v string
  for all the nodes for that metric."
  (let* ((node-ids (-map 'first (-partition 2 info-plist)))
         (metric-of-nodes (-map (lambda (id)
                                  (-> (plist-get info-plist id)
                                      (plist-get metric)))
                                node-ids))
         (bounds (plist-get es-cc--bounds-for-metric metric))
         (___ (message "Bounds %s metric: %s" bounds metric))
         (min (plist-get bounds :min))
         (min-val (cond
                   ((numberp min)
                    min)
                   ((eq min :auto)
                    (-min metric-of-nodes))
                   (t 0)))
         (_ (message "Min: %d" min-val))
         (max (plist-get bounds :max))
         (max-val (cond
                   ((numberp max)
                    max)
                   ((eq max :auto)
                    (-max metric-of-nodes))
                   (t 10)))
         (__ (message "Max: %d" max-val)))
    (spark-v metric-of-nodes
             :min min-val
             :max max-val
             :labels node-ids)))

;; TODO: rename this
(defun m/merge (plist-a &rest plist-b)
  (-reduce-from
   (lambda (plist-a plist-b)
     (->> (-partition 2 plist-b)
          (-reduce-from
           (lambda (acc it)
             (let ((key (first it))
                   (val (second it)))
               (plist-put acc key val)))
           plist-a)))
   plist-a
   plist-b))

(defun es-cc--node-to-info (node-tuple)
  "Returns plist of node name to plist of metrics"
  (let* ((node-id (first node-tuple))
         (node-stat (second node-tuple))
         (name (plist-get node-stat :name))
         (host (plist-get node-stat :host))
         (mem-pct (-> node-stat
                      (plist-get :jvm)
                      (plist-get :mem)
                      (plist-get :heap_used_percent)))
         (cpu-stats (-> node-stat
                        (plist-get :os)
                        (plist-get :cpu)))
         (cpu-pct (or (-> node-stat
                          (plist-get :os)
                          (plist-get :cpu_percent))
                      (-> cpu-stats (plist-get :percent))))
         (load-avg (or (-> node-stat
                           (plist-get :os)
                           (plist-get :load_average))
                       (-> cpu-stats
                           (plist-get :load_average)
                           (plist-get :1m)))))
    (plist-put '() node-id
               (-> (plist-put '() :name name)
                   (plist-put :host host)
                   (plist-put :cpu cpu-pct)
                   (plist-put :mem mem-pct)
                   (plist-put :load load-avg)))))

(defun es-cc--build-map-from-nodes-stats (stats-json)
  (let* ((json-object-type 'plist)
         (data (json-read-from-string stats-json))
         (cluster-name (plist-get data :cluster_name))
         (nodes (plist-get data :nodes))
         (node-names (->> nodes (-partition 2) (-map 'first)))
         (node-infos (->> nodes (-partition 2) (-map 'es-cc--node-to-info))))
    (-reduce 'm/merge node-infos)))

(defun es-cc--process-nodes-stats (status &optional results-buffer)
  (let* ((http-results-buffer (current-buffer))
         (body-string (with-temp-buffer
                        (url-insert http-results-buffer)
                        (goto-char (point-min))
                        (search-forward "{" (point-max))
                        (buffer-substring-no-properties
                         (- (point) 1) (point-max))))
         (http-status-code url-http-response-status)
         (http-content-type url-http-content-type)
         (http-content-length url-http-content-length))
    (set-buffer
     (get-buffer-create results-buffer))
    (message "Response: Status: %S Content-Type: %S (%s bytes)"
             http-status-code http-content-type http-content-length)
    (let ((buffer-read-only nil))
      ;; Clear everything
      (delete-region (point-min) (point-max))
      (if (or (equal 'connection-failed (cl-cadadr status))
              (not (numberp http-status-code)))
          (progn
            (insert "ERROR: Could not connect to server.")
            (setq mode-name (format "ES-CC[failed]")))
        (fundamental-mode)
        ;; Turn on ES-CC mode
        (es-command-center-mode)
        ;; Insert the new stats
        (let ((stats (es-cc--build-map-from-nodes-stats body-string)))
          (insert "* Node Information\n"
                  (format-time-string "Last Updated: [%FT%T%z]\n")
                  (format "Nodes: %s\n"(-map 'first (-partition 2 stats)))
                  "\n* Node Memory"
                  (es-cc--spark-v-for-metric stats :mem)
                  "\n* Node CPU"
                  (es-cc--spark-v-for-metric stats :cpu)
                  "\n* Node Load"
                  (es-cc--spark-v-for-metric stats :load)))))
    (read-only-mode 1)))

(defun es-cc-get-nodes-stats (buffer-name)
  (url-retrieve (es-cc-get-nodes-stats-endpoint)
                'es-cc--process-nodes-stats
                (list buffer-name)
                t t))

(defun es-cc-refresh ()
  "Refresh the stats for the current buffer"
  (interactive)
  (es-cc-get-nodes-stats (buffer-name)))

(defun es-command-center ()
  "Open the Elasticsearch Command Center"
  (interactive)
  (let ((buffer-name (format "*ES-CC: %s*" es-cc-endpoint)))
    (set-buffer
     (get-buffer-create buffer-name))
    ;; Clear everything
    (let ((buffer-read-only nil))
      (delete-region (point-min) (point-max))
      (insert (format "Fetching stats [%s]..." es-cc-endpoint)))
    (set-window-buffer nil buffer-name)
    (es-cc-get-nodes-stats buffer-name)))

(defvar es-command-center-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") 'es-cc-refresh)
    (define-key map (kbd "q") 'bury-buffer)
    map)
  "Keymap used for `es-command-center-mode'.")

(define-minor-mode es-command-center-mode
  "Docstring"
  :init-value nil
  :lighter "ES-CC"
  :group 'es-cc
  :keymap es-command-center-mode-map)

;; Testing niceties, will be removed before release
(defun get-string-from-file (filePath)
  "Return filePath's file content."
  (with-temp-buffer
    (insert-file-contents filePath)
    (buffer-string)))

(defvar example-2-node-stats
  (get-string-from-file "example.json"))

(defvar example-5-node-stats
  (get-string-from-file "example5.json"))

(defun example-single-node ()
  (let* ((json-object-type 'plist)
         (data (json-read-from-string example-node-stats))
         (nodes (plist-get data :nodes))
         (node-names (->> nodes (-partition 2) (-map 'first))))
    (plist-get nodes (first node-names))))

(provide 'es-cc)
;;; es-cc.el ends here