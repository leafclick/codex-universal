(ns lsp-fixture.core
  (:require [clojure.string :as str]))

(defn normalized-label [value]
  (str/upper-case (str/trim value)))

(defn public-message [value]
  (str "fixture:" (normalized-label value)))

(defn message-length [value]
  (count (public-message value)))
