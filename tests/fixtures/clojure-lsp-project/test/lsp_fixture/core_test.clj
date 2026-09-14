(ns lsp-fixture.core-test
  (:require [clojure.test :refer [deftest is]]
            [lsp-fixture.core :as sut]))

(deftest public-message-test
  (is (= "fixture:HELLO" (sut/public-message " hello ")))
  (is (= 13 (sut/message-length " hello "))))
