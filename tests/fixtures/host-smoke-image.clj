#!/usr/bin/env bb

(require '[babashka.process :as process]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(import '(java.io File RandomAccessFile)
        '(java.nio.charset StandardCharsets)
        '(java.util.concurrent TimeUnit))

(defn positive-long [name default]
  (if-let [raw (System/getenv name)]
    (try
      (let [value (Long/parseLong raw)]
        (when-not (pos? value)
          (throw (ex-info "not positive" {})))
        value)
      (catch Exception _
        (binding [*out* *err*]
          (println (format "host-smoke: %s must be a positive integer, got %s"
                           name (pr-str raw))))
        (System/exit 2)))
    default))

(defn duration [started-nanos]
  (format "%.1fs" (/ (- (System/nanoTime) started-nanos) 1.0e9)))

(defn bounded-tail [^File file]
  (when (and (.isFile file) (pos? (.length file)))
    (with-open [input (RandomAccessFile. file "r")]
      (let [length (.length input)
            start (max 0 (- length 65536))
            bytes (byte-array (int (- length start)))]
        (.seek input start)
        (.readFully input bytes)
        (->> (String. bytes StandardCharsets/UTF_8)
             str/split-lines
             (take-last 40)
             (str/join "\n"))))))

(defn print-log-tail [label file]
  (when-let [tail (some-> (bounded-tail file) str/trim not-empty)]
    (binding [*out* *err*]
      (println (str "--- " label " (last 40 lines, 64 KiB maximum) ---"))
      (println tail))))

(def phase-specs
  [{:id "identity"               :name "runtime identity"          :timeout 10}
   {:id "filesystem-policy"      :name "filesystem policy"         :timeout 15}
   {:id "toolchain-availability" :name "installed toolchain"       :timeout 15}
   {:id "clojure-runtime"        :name "Clojure runtime lifecycle" :timeout 180}
   {:id "bubblewrap"             :name "nested Bubblewrap sandbox" :timeout 30}
   {:id "clojure-lsp-runtime"    :name "sandboxed Clojure LSP"     :timeout 30}
   {:id "clojure-lsp"            :name "Clojure MCP/LSP workflow"  :timeout 210}
   {:id "cli-smoke"              :name "installed CLI smoke"       :timeout 60}
   {:id "cuda-runtime"           :name "CUDA runtime"              :timeout 60
    :profile "cuda"}])

(let [[profile runtime-uid runtime-gid image :as arguments] *command-line-args*]
  (when-not (= 4 (count arguments))
    (binding [*out* *err*]
      (println "usage: host-smoke-image.clj PROFILE UID GID IMAGE"))
    (System/exit 2))

  (let [phase-script (or (System/getenv "CODEX_IMAGE_SMOKE_PHASE_SCRIPT")
                         "/tmp/host-smoke-image.sh")
        phase-wrapper (or (System/getenv "CODEX_IMAGE_SMOKE_PHASE_WRAPPER")
                          "/tmp/host-smoke-image-phase.sh")
        heartbeat-seconds (positive-long "CODEX_TEST_IMAGE_HEARTBEAT_SECONDS" 10)
        kill-after-seconds (positive-long "CODEX_TEST_IMAGE_KILL_AFTER_SECONDS" 5)
        phases (vec (filter #(or (nil? (:profile %))
                                 (= profile (:profile %)))
                            phase-specs))
        maximum-seconds (reduce + (map :timeout phases))
        log-directory (doto (io/file (or (System/getenv "CODEX_IMAGE_SMOKE_LOG_DIR")
                                         "/tmp/host-smoke-image-logs"))
                        .mkdirs)
        suite-started (System/nanoTime)]
    (println (format "IMAGE  %s (%s): %d phases, maximum %ds"
                     image profile (count phases) maximum-seconds))
    (flush)
    (loop [remaining phases
           passed 0]
      (if-let [{:keys [id name timeout]} (first remaining)]
        (let [number (inc passed)
              stdout-file (io/file log-directory (str id ".stdout.log"))
              stderr-file (io/file log-directory (str id ".stderr.log"))
              command ["timeout"
                       "--signal=TERM"
                       (str "--kill-after=" (+ kill-after-seconds 2) "s")
                       (str timeout "s")
                       "setsid"
                       "/bin/bash"
                       phase-wrapper
                       phase-script
                       id
                       profile
                       runtime-uid
                       runtime-gid
                       image]
              phase-started (System/nanoTime)]
          (println (format "START  [%d/%d] %s (timeout %ds)"
                           number (count phases) name timeout))
          (flush)
          (try
            (let [running (process/process command
                                           {:out stdout-file
                                            :err stderr-file})]
              (loop []
                (when-not (.waitFor (:proc running)
                                    heartbeat-seconds
                                    TimeUnit/SECONDS)
                  (println (format "WAIT   [%d/%d] %s (%s elapsed, timeout %ds)"
                                   number (count phases) name
                                   (duration phase-started) timeout))
                  (flush)
                  (recur)))
              (let [status (:exit @running)]
                (when-not (zero? status)
                  (binding [*out* *err*]
                    (println (format "%-7s[%d/%d] %s after %s (exit %d)"
                                     (case status
                                       124 "TIMEOUT"
                                       137 "KILLED"
                                       "FAIL")
                                     number (count phases) name
                                     (duration phase-started) status)))
                  (print-log-tail "stderr" stderr-file)
                  (print-log-tail "stdout" stdout-file)
                  (binding [*out* *err*]
                    (println (format "SUMMARY  %d/%d phases passed in %s"
                                     passed (count phases)
                                     (duration suite-started))))
                  (System/exit 1)))
              (println (format "PASS   [%d/%d] %s (%s)"
                               number (count phases) name
                               (duration phase-started)))
              (flush))
            (catch Throwable error
              (binding [*out* *err*]
                (println (format "FAIL   [%d/%d] %s: %s"
                                 number (count phases) name (.getMessage error)))
                (println (format "SUMMARY  %d/%d phases passed in %s"
                                 passed (count phases) (duration suite-started))))
              (System/exit 1)))
          (recur (subvec remaining 1) (inc passed)))
        (do
          (println (format "SUMMARY  %d/%d phases passed in %s"
                           passed (count phases) (duration suite-started)))
          (flush))))))
