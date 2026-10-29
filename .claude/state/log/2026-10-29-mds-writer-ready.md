# 2026-10-29 MDS 寫入前：等寫入者就緒，不靠重試（使用者決定）

## 背景
- 使用者：「重試是沒有招了才用，應該用更好的判斷」。選項定案：**等就緒，拿掉重試**（含先前就有的 5 處 `retry 3 5`）。
- 出錯當下四台 MDS 的 8090 都回 200：「MDS 活著」擋不住；失敗的是寫入（50003 not the current leader）。

## 判斷依據
- MDS 寫在 `_confluent-metadata-auth` 的 Status 紀錄：每次 broker 進出，寫入者重選，generationId 加一，先 `INITIALIZING`、就緒後 `INITIALIZED`。
  事故（2026-10-29 早上）時一直停在 INITIALIZING；暫時性 50003 就是夾在兩筆之間。
- `mds-writer-ready.sh`：kafka-internal 走 9092 讀整個 topic 一次（5 秒沒新資料即結束），每個 partition 取最新 Status；全部 INITIALIZED 且 generation 一致才回 0，最多等 300 秒。就緒時約 12 秒（JVM 起動佔大半；改版前分 partition 讀要 27 秒）。

## 放在哪裡
- 腳本：`lib/log.sh` 的 `wait_mds_writer`；`rolling_restart brokers` 最後、10.4 broker 起來後、29／30 的 broker 健康檢查、25.2 加 broker、28 recover；
  成批寫 binding 前：11、16、18、23（grant／restore／drill）、27（onboard／retire）、29（svc-rest ResourceOwner）。MDS 寫入的 retry 全拿掉（0 處）。
- 手冊：第 11 章 bootstrap 之前建立 `~/conf/mds-writer-ready.sh`（圖 D.mdswriter）；14 個重啟 broker 的區塊結尾、`rolling-restart.sh` 內、7 個成批寫 binding 的區塊開頭呼叫；23.6 restore 腳本開頭呼叫；27.6 與 23.6 的重試拿掉；28.4 加 50003 一列。

## 待驗
- 手動：重啟一台 broker 後，檢查要先報「沒就緒」（INITIALIZING 或 generation 不一致），就緒後寫入一次成功。要等腳本版從零重跑結束才能動 broker。
- 之後的手冊 A→B 從零實跑會驗到全部 25 個呼叫點（out 的 generation／秒數要填實際值）。
