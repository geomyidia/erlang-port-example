(defmodule ports.go.server
  (behaviour gen_server)
  ;; gen_server implementation
  (export
   (start_link 0)
   (stop 0))
  ;; callback implementation
  (export
   (code_change 3)
   (handle_call 3)
   (handle_cast 2)
   (handle_info 2)
   (init 1)
   (terminate 2))
  ;; Go server API
  (export
   (send 1))
  ;; management API
  (export
   (healthy? 0)
   (os-process-alive? 0)
   (state 0)
   (status 0))
  ;; debug API
  (export
    (pid 0)
    (echo 1)))

(include-lib "logjam/include/logjam.hrl")

;;;;;::=--------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   config functions   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=--------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun SERVER () (MODULE))
(defun DELIMITER () #"\n")
(defun GO-BIN () (++
  (code:priv_dir 'ports)
  "/"
  "go/src/github.com/geomyidia/erlang-ports-example/bin/echo"))
(defun GO-TIMEOUT () 100)

(defun initial-state ()
  `#m(opts ()
      args ()
      binary ,(GO-BIN)
      pid undefined
      os-pid undefined))

(defun genserver-opts () '())
(defun unknown-command (data)
  `#(error ,(lists:flatten (++ "Unknown command: " data))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;   gen_server API   ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun start_link ()
  (log-info "Starting Go server controller ...")
  (gen_server:start_link `#(local ,(SERVER))
                         (MODULE)
                         (initial-state)
                         (genserver-opts)))

(defun stop ()
  (gen_server:call (MODULE) 'stop))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;   Supervisor Callbacks   ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun init (state)
  (log-debug "Initialising Go server controller ...")
  (erlang:process_flag 'trap_exit 'true)
  (let ((start-state (start-exec (self) state)))
    (log-debug "Start state: ~p" (list start-state))
    `#(ok ,(maps:merge state start-state))))

(defun handle_call
  ;; Management
  ((`#(state) _from state)
   `#(reply ,state ,state))
  ((`#(status os-process) _from (= `#m(os-pid ,os-pid) state))
   `#(reply ,(ps-alive? os-pid) ,state))
  ;; Stop
  (('stop _from state)
   (log-notice "Stopping Go server ...")
   `#(stop normal ok ,state))
  ;; Testing / debugging
  ((`#(echo ,msg) _from state)
   `#(reply ,msg ,state))
  ;; Fall-through
  ((message _from state)
   `#(reply ,(unknown-command (io_lib:format "~p" `(,message))) ,state)))

(defun handle_cast
  ;; Simple command (new format)
  (((= `(#(command ,_)) cmd) (= `#m(os-pid ,os-pid) state))
   (let ((hex-msg (hex-encode cmd)))
     (exec:send os-pid hex-msg)
     `#(noreply ,state)))
  ;; Command with args
  (((= `(#(command ,_) #(args ,_)) cmd) (= `#m(os-pid ,os-pid) state))
   (let ((hex-msg (hex-encode cmd)))
     (exec:send os-pid hex-msg)
     `#(noreply ,state)))
  ;; Go server commands - old format, still used
  (((= `#(command ,_) cmd) (= `#m(os-pid ,os-pid) state))
   (let ((hex-msg (hex-encode cmd)))
     (exec:send os-pid hex-msg)
     `#(noreply ,state)))
  ((msg state)
   (log-warn "Got undexected cast msg: ~p" (list msg))
   `#(noreply ,state)))

(defun handle_info
  ;; Standard-output messages
  ((`#(stdout ,_pid ,msg) state)
   (io:format "~s" (list (binary_to_list msg)))
   `#(noreply ,state))
  ;; Standard-error messages
  ((`#(stderr ,_pid ,msg) state)
   (io:format "~s" (list (binary_to_list msg)))
   `#(noreply ,state))
  ;; Port EOL-based messages
  ((`#(,port #(data #(eol ,msg))) state) (when (is_port port))
   (log-info (sanitize-goserver-msg msg))
   `#(noreply ,state))
  ;; Port line-based messages
  ((`#(,port #(data #(,line-msg ,msg))) state) (when (is_port port))
   (log-info "Unknown line message:~p~s" `(,line-msg ,(sanitize-goserver-msg msg)))
   `#(noreply ,state))
  ;; General port messages
  ((`#(,port #(data ,msg)) state) (when (is_port port))
   (log-info "Message from the Go server port:~n~s" `(,(sanitize-goserver-msg msg)))
   `#(noreply ,state))
  ;; Exit-handling
  ((`#(,port #(exit_status ,exit-status)) state) (when (is_port port))
   (log-warn "~p: exited with status ~p" `(,port ,exit-status))
   `#(noreply ,state))
  ((`#(EXIT ,_from normal) state)
   (logger:info "The Go server controller is exiting (normal).")
   `#(noreply ,state))
  ((`#(EXIT ,_from shutdown) state)
   (logger:info "The Go server controller is exiting (shutdown).")
   `#(noreply ,state))
  ((`#(EXIT ,pid ,reason) state)
   (log-notice "Process ~p exited! (Reason: ~p)" `(,pid ,reason))
   `#(noreply ,state))
  ;; Fall-through
  ((msg state)
   (log-debug "Unknwon info: ~p" `(,msg))
   `#(noreply ,state)))

(defun terminate
  ((reason `#m(os-pid ,os-pid))
   (log-notice "Terminating the Go server controller (~p)..." `(,reason))
   (catch (exec:stop os-pid))
   'ok))

(defun code_change (_old-version port _extra)
  `#(ok ,port))

;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   Go server API   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun send (msg)
  (erlang:process_flag 'trap_exit 'true)
  (try
      (gen_server:cast (MODULE) msg)
    (catch
      ((tuple 'exit `#(noproc ,_) _stack)
       (log-err "Go server not running"))
      ((tuple type value stack)
       (log-err "Unexpected port error.~ntype: ~p~nvalue: ~p~nstacktrace: ~p"
                (list type value stack))))))

;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   management API   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun healthy? ()
  (let ((vals (maps:values (status))))
    (not (lists:member 'false vals))))

(defun os-process-alive? ()
  (gen_server:call (SERVER) #(status os-process)))

(defun state ()
  (gen_server:call (SERVER) #(state)))

(defun status ()
  (gen_server:call (SERVER) #(status all)))

;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   debugging API   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=-----------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun pid ()
  (erlang:whereis (SERVER)))

(defun echo (msg)
  (gen_server:call (SERVER) `#(echo ,msg)))

;;;;;::=-------------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   exec (port) functions   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=-------------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun start-exec
  ((mgr-pid (= `#m(args ,args binary ,bin) state))
   (log-debug "Starting Go server executable ...")
   (maps:merge state (run mgr-pid bin args))))

(defun run (mgr-pid cmd args)
  (run mgr-pid cmd args #m()))

(defun run (mgr-pid cmd args opts)
  (let ((opts (run-opts mgr-pid opts)))
    (log-debug "Starting OS process ~s with args ~p and opts ~p"
               (list cmd args opts))
    (let ((exec-str (join-cmd-args cmd args)))
      (log-debug "Using exec string: ~s" (list exec-str))
      (let ((`#(ok ,pid ,os-pid) (exec:run_link exec-str opts)))
        `#m(pid ,pid os-pid ,os-pid)))))

;;;;;::=-------------------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;::=-   utility / support functions   -=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;::=-------------------------------=::;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun sanitize-goserver-msg (msg)
  (log-debug "Binary message: ~p" `(,msg))
  (clj:-> msg
          (binary_to_list)
          (string:replace "\\" "")
          (string:trim)))

(defun join-cmd-args (cmd args)
  (clj:-> (list cmd)
          (lists:append args)
          (string:join " ")))

(defun default-run-opts (mgr-pid)
  `(stdin
    pty
    #(stdout ,mgr-pid)
    #(stderr ,mgr-pid)
    monitor))

(defun run-opts (mgr-pid opts)
  (if (maps:is_key 'run-opts opts)
    (mref opts 'run-opts)
    (default-run-opts mgr-pid)))

(defun has-str? (string pattern)
  (case (string:find string pattern)
    ('nomatch 'false)
    (_ 'true)))

(defun ps-alive? (os-pid)
  (has-str? (ps-pid os-pid) (integer_to_list os-pid)))

(defun ps-pid (pid-str)
  (os:cmd (++ "ps -o pid -p" pid-str)))

(defun hex-encode (data)
  (let* ((bin (erlang:term_to_binary data))
         (delim (DELIMITER))
         (hex-msg (binary ((bin->hex bin) binary) (delim binary))))
    (log-debug "Created hex msg: ~p" (list hex-msg))
    hex-msg))

(defun go-log-level (lfe-level)
  (case lfe-level
    ('all "trace")
    ('debug "debug")
    ('info "info")
    ('notice "warning")
    ('warning "warning")
    ('error "error")
    (_ "fatal")))

(defun bin->hex (bin)
  (if (>= (list_to_integer (erlang:system_info 'otp_release)) 24)
    (let ((mod 'binary)
          (func 'encode_hex))
      (call mod func bin))
    (progn
      (log-debug "Getting hex for: ~s" `(,(lfe_io_format:fwrite1 "~p" (list bin))))
      (list_to_binary
       (lists:flatten
        (list-comp ((<- x (binary_to_list bin)))
          (io_lib:format "~2.16.0B" `(,x))))))))
