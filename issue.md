# CoTime Book — 已知問題追蹤

這份文件記錄在專案中發現的問題。**每次開始工作前先讀這份文件**，確認哪些是
已修復（回歸測試守著）、哪些還開著。修好一項就把它從「開放中」移到「已修復」，
並補上對應的測試。

狀態標記：`[x]` 已修復並有測試 · `[ ]` 開放中 · `[~]` 部分緩解

---

## 已修復

### [x] #1 翻頁失敗後的錯誤橫幅永遠不會消失

- **檔案**：`lib/services/page_sync_service.dart`、`lib/widgets/sync_status_bar.dart`
- **症狀**：畫面頂端一直卡著「Waiting for every reader to become ready」之類的粉紅色橫幅，
  看起來像整個 App 死鎖了。
- **原因**：`PageSyncState.error(...)` 沒有任何清除路徑。`SyncStatusBar` 只要
  `errorMessage != null` 就優先畫錯誤列，蓋掉真正的狀態。但協定本身每一種失敗都會
  回到 `SyncStatus.idle`——也就是說翻頁其實還能用，只是橫幅騙人。
- **修法**：`PageSyncService` 加上 `_errorAutoClearTimer`，錯誤狀態在
  `defaultErrorAutoClearDelay`（6 秒）後自動回到 idle。延遲時間可注入，測試用短值。
- **測試**：`test/page_sync_service_test.dart` →
  `a transient failure clears itself instead of pinning the bar`

### [x] #2 翻頁 quorum 用的是沒合併過的 Presence metas

- **檔案**：`lib/services/realtime_service.dart`、`lib/services/presence_merge.dart`
- **症狀**：明明所有人都在讀，卻一直「Waiting for every reader to become ready」。
- **原因**：Supabase Presence 是**每條連線一筆** meta，而且 channel key 帶了
  microsecond timestamp（`_SupabaseRoomRealtimeChannel` 建構子），所以同一個使用者
  可能同時有多筆：第二台裝置，或重連後還沒過期的舊 meta。
  `RealtimeService.getOnlineUsers()` 直接回傳原始 payload，
  `PageSyncService._buildReadyReaderQuorum()` 又用 last-wins 的 map 去查，
  只要最後一筆是 `is_reading: false` 的殘留 meta，這個人就永遠不會 ready。
  諷刺的是 `mergePresenceUsers` 早就存在了，只有 `PresenceNotifier` 在用。
- **修法**：把 `mergePresenceUsers` 抽到 `lib/services/presence_merge.dart`，
  在 `RealtimeService.getOnlineUsers()` 這個邊界就合併，讓所有消費端（quorum、lobby
  名單、status bar）看到同一份「一個 user 一列」的資料。
- **測試**：`test/realtime_service_test.dart` →
  `online users collapse a user with several connections`

### [x] #3 有人加入房間時，lobby 不會顯示新成員

- **檔案**：`lib/providers/room_provider.dart`
- **症狀**：B 加入房間後，A 的成員清單完全沒變；連帶 Start Reading 也會因為
  `participant_user_ids` 與 `members` 對不起來而報「The reading session roster is out of date.」
- **原因**：`refreshMembers()` 的守衛寫成
  `if (!identical(state.members, originalMembers)) return;`。
  而 lobby 的 `ref.listen<PresenceState>` 在**同一個 callback 裡**先呼叫
  `updateMembersFromPresence()`（每次都無條件配置一個新 list），才觸發 `refreshMembers()`。
  Presence 的 `join` 事件後面一定緊跟一個 `sync` 事件，於是在 DB 讀取 await 的期間
  `state.members` 又被換掉一次 → `identical` 失敗 → **剛抓回來、含有新成員的名單被整包丟棄**。
- **修法**：
  - 守衛改成 `_membersFetchGeneration`：只有「更新的 fetch」能作廢舊 fetch，
    Presence overlay 不再把 roster 丟掉。
  - `RoomNotifier` 快取 `_lastPresenceUsers`，fetch 落地後重新套用 online / has_book。
  - `updateMembersFromPresence()` 在內容沒有實際變化時不寫 state（減少無謂 rebuild）。
  - 換房 / 離開 / 撤銷 session 時用 `_resetMemberTracking()` 清掉快取。
- **測試**：`test/room_provider_test.dart` →
  `a member who joins mid-refresh survives a presence overlay`、
  `a superseded roster read is discarded by the newer one`、
  `presence with no roster change does not churn state`

### [x] #4 加入房間沒有任何廣播通知其他人

- **檔案**：`lib/providers/presence_provider.dart`、`lib/screens/room_lobby_screen.dart`
- **原因**：只有 `announceLeaving()`。Presence 的 join 只說「有一條連線出現」，
  不代表資料庫 roster 變大，其他人沒有明確訊號去重讀權威名單。
- **修法**：新增 `announceJoining()`，lobby 在 presence join 成功後廣播
  `membership_changed {action: 'joined'}`。收到 `joined` 不需要等 200ms
  （join 廣播時 RPC 已經 commit 了，只有 leave 才需要等）。同時忽略自己發出的廣播。

### [x] #5 reader 會在 viewer 還沒 ready 時對外宣告 `reader_ready: true`

- **檔案**：`lib/screens/reader_screen.dart`（`onRelocated`）
- **原因**：同一段程式裡，`updateReaderContext()` 用的是
  `_isReaderReady && _displayingTargetCfi == null`，但 `updateReaderReady(true)`
  是**無條件**呼叫的。結果本機 `PageSyncService` 認為自己沒 ready，Presence 卻告訴
  全房這個 client ready。其他人把它算進 quorum，它再把授權過的請求打回票。
- **修法**：兩邊共用同一個 `isReadyNow`。

### [x] #6 從沒進入 reader 的參與者會永久卡住 quorum

- **檔案**：`lib/services/page_sync_service.dart`（`_onPresenceChange`）
- **原因**：`_expectedParticipantUserIds` 由 start_reading 凍結，而移除路徑只有兩條：
  明確的 `reading_session_leave` 廣播，或「**曾經**進過 reader」的人離線
  （`_enteredReaderParticipantIds`）。因此有人停在 lobby、或直接關掉 App，
  就會永遠留在 quorum 裡，全房再也翻不了頁。
- **修法**：Presence 事件時，把完全不在房間頻道上的參與者移出 quorum。
  「不在頻道上」是所有 client 觀察一致的事實，roster 仍然收斂；
  只要重新出現在頻道上就會被 `_syncParticipantRoster()` 加回來（不論是否在 reader 裡）——
  短暫斷線不該讓一個人永久退出 quorum，也不該讓「斷過線的 lobby 參與者」
  比「一直連著的 lobby 參與者」享有不同待遇。
  仍留在 lobby（有 presence 但 `is_reading: false`）的人依然會擋——這是刻意的，
  但現在訊息會指名是誰（見 #7）。
- **測試**：`test/page_sync_service_test.dart` →
  `a participant who never opened the reader stops blocking once offline`

### [x] #7 錯誤訊息把 protocol 代碼直接丟給使用者

- **檔案**：`lib/services/page_sync_service.dart`
- **症狀**：「Page turn cancelled: declined_by_Bob」、「Page turn cancelled:
  required_reader_not_ready」、「Waiting for every reader to become ready」
  （不知道在等誰）。
- **修法**：
  - `describeCancelReason()` 把 wire reason 轉成人話（wire 上仍傳原始代碼）。
  - quorum 失敗訊息會指名還沒 ready 的人：「Waiting for Bob to become ready」。
- **測試**：`test/page_sync_service_test.dart` →
  `the quorum failure names the reader that is holding it up`、
  `presence sync cancels when a required reader becomes unready`

### [x] #8 `_recoverAuthoritativePosition` 可能無限輪詢並凍結 reader

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：`refreshRoomAndGet()` 在 revision 沒變、且 `currentRoom` 物件在期間被
  其他更新換掉時會回傳 `null`（`_applyRoomUpdate` 的 `identical(currentRoom, originRoom)`
  判斷失敗）。外層 `while` 每 2 秒重試且沒有出口，而擋住所有手勢的
  `_recoveringAuthoritativePosition` 只有在迴圈結束後才清除。
- **修法**：改成 `_maxPositionRecoveryAttempts = 10` 的有界迴圈，用完就落回 `fallbackCfi`。

### [x] #9 `_initReader` 可能讓 `_currentCfi` 與畫面不同步

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：`_rebuildViewer()` 在 `_isStoppingPageSync` 或有進行中請求時會提早 return，
  但呼叫端已經先把 `_currentCfi` 指派成從 DB 抓回來的 freshCfi。viewer 還停在舊位置，
  這個 client 卻對外宣稱自己在 freshCfi。
- **修法**：`_rebuildViewer()` 回傳 `bool`，被拒絕時呼叫端還原 `_currentCfi`。

### [x] #10 成員超過畫面高度時無法捲動

- **檔案**：`lib/widgets/member_list.dart`
- **原因**：`ListView.builder` 放在 `Expanded` 裡卻設了 `shrinkWrap: true` +
  `NeverScrollableScrollPhysics`，超出的成員被裁掉且滑不到。

### [x] #11 reader 的「No book loaded」是死路

- **檔案**：`lib/screens/reader_screen.dart`
- **原因**：這個分支沒有返回按鈕也沒有 `PopScope`。reader 是用 `go` 進來的、沒有
  navigation stack，硬體返回會直接離開 App。
- **修法**：補上 `PopScope` 與「Back to Lobby」按鈕。

---

## 開放中

### [ ] #A 不同螢幕尺寸的裝置之間 CFI 對不起來（設計層級，優先）

- **檔案**：`lib/screens/reader_screen.dart`、`lib/services/page_sync_service.dart`
- **問題**：`onRelocated` 第一次回報的 `location.startCfi` 是 epub.js 依**實際分頁**
  算出來的，取決於視窗大小、字級與 flow 設定。兩台螢幕尺寸不同的手機在同一頁會得到
  不同的 CFI 字串。而 `_isValidIncomingRequest()` 要求
  `_currentCfi == request.fromCfi` **字串完全相等**，所以跨尺寸裝置的第一次翻頁
  會被 follower 打回 `invalid_or_stale_request`。
- **為什麼不是每次都爆**：翻頁成功後 follower 會透過 `_displayingTargetCfi` 採用
  requester 的 targetCfi，之後大家的 `_currentCfi` 就一致了。所以只有
  **進 reader 後的第一次**、以及任何一次 `_rebuildViewer()`（換主題、CFI 變更）之後
  會踩到。
- **可能的修法**：
  1. reading session 開始時由 host 廣播一個 anchor CFI，所有人 `display(cfi:)` 到那裡，
     並像 follower 一樣把 anchor 當成自己的 `_currentCfi`（而不是採用本機 startCfi）。
  2. 或者把相等性判斷從「字串相等」放寬成「spine index 相同」，只用 CFI 字串做顯示。
- **注意**：這會動到 consensus 的核心判斷，必須先補測試再改。

### [ ] #H reader_screen.dart 沒有任何測試

- **檔案**：`lib/screens/reader_screen.dart`
- **問題**：這個檔案是整個 App 狀態最多的地方（`_isReaderReady`、`_displayingTargetCfi`、
  `_pendingAuthoritativeCfiSync`、`_recoveringAuthoritativePosition`、`_isStoppingPageSync`
  互相牽動），但完全沒有測試。這次 PR 的 code review 找出 10 個問題，其中 7 個在這個檔案，
  而且全都是同一種形狀：「某個地方發布 readiness 時漏掉了一個條件」。
- **已做的緩解**：readiness 改成由 `_isReadyForTurns` 單一推導、
  透過 `_publishReadiness()` 單一發布，呼叫端只改 state 不再自己算值——
  讓「漏掉條件」這類 bug 在結構上不可能發生。
  （進入 / 離開 reader 的 lifecycle 路徑仍保留顯式的 await 順序，那是刻意的。）
- **還缺的**：`EpubViewer` 需要真的 WebView 才能跑，所以要測這個畫面得先把
  viewer 抽成介面（像 `PageSyncTransport` 那樣注入），才能在測試裡驅動
  `onChaptersLoaded` / `onRelocated`。在那之前，這個檔案的改動只能靠實機驗證。

### [ ] #G 同一使用者多個 reader session 的 readiness 是 OR 合併的

- **檔案**：`lib/services/presence_merge.dart`
- **問題**：`mergePresenceUsers` 用 `metas.any(...)` 合併 `reader_ready`。
  如果同一個 user_id 同時有兩個都在讀的 session（真的兩台裝置），其中一台還在載入，
  合併結果仍然是 ready。其他人的 quorum 把這個 user 算進去、發出請求，
  那台還沒 ready 的裝置卻會在 `_isValidIncomingRequest` 把它打回票 → 翻頁被取消。
- **為什麼現在不改**：
  - OR 對**目前實際會發生**的情況是正確的：重連後殘留的舊 meta 帶著
    `reader_ready: true`，那是同一個人同一個閱讀狀態，OR 剛好處理對
    （這正是 #2 修掉的那個 bug）。改成 AND 反而會讓「斷線瞬間殘留一筆
    `reader_ready: false`」重新變成阻塞。
  - 真正的多裝置情境在這個 App 幾乎不會發生：auth 是匿名的，每次安裝就是一個新的
    user_id，兩台裝置不會共用同一個 user_id。
  - 這個問題的根源跟 **#A 是同一個**：per-connection 的狀態被硬塞進 per-user 的
    quorum。要修就得一起修，不能只動合併規則。
- **如果要修**：`reader_ready` 改成「所有 `is_reading == true` 的 meta 都 ready」
  （沒有任何 reading meta 時為 false），而 `is_reading` 維持 OR。
  這比「挑一個 canonical session」更正確，但會需要改
  `test/presence_provider_test.dart` 裡
  `mergePresenceUsers deduplicates sessions by user_id` 的預期值——
  那個測試目前把「lobby 的 session 帶著 stale `reader_ready: true`」也算成 ready。

### [ ] #B `copyWith` 預設會靜默清掉 `error`

- **檔案**：`lib/providers/room_provider.dart`、`lib/providers/book_provider.dart`、
  `lib/providers/auth_provider.dart`
- **問題**：三個 state 都寫成 `error: error`（而不是 `error ?? this.error`），
  代表任何沒帶 `error` 參數的 `copyWith()` 都會把既有錯誤清掉。
  `RoomNotifier._applyRoomUpdate` 得靠手動傳 `error: state.error` 才能保住錯誤，
  跟 `PageSyncState` 的 `clearError` 慣例不一致。
- **影響**：目前沒有明顯的使用者可見 bug（錯誤本來就短命），但很容易誤用。
- **建議**：統一成 `error ?? this.error` + 顯式的 `clearError` 旗標，並逐一檢查呼叫點。

### [ ] #C reader 的成員面板不會即時更新

- **檔案**：`lib/screens/reader_screen.dart`（`_showMembersDrawer`）
- **問題**：用 `ref.read(presenceProvider)` 取一次 snapshot 就畫，bottom sheet 打開
  期間有人進出不會反映。應該用 `Consumer` 包起來。

### [ ] #D reader 進場的頭幾毫秒會丟掉 page_turn 事件

- **檔案**：`lib/services/realtime_service.dart`
- **問題**：channel 建立時就對所有 `roomEvents` 註冊 callback，但事件是丟進
  `_broadcastControllers[event]?.add(payload)`——controller 只在
  `broadcastStream(event)` 第一次被呼叫時才建立。從進入 reader 到
  `PageSyncService.initialize()` 之間抵達的 `page_turn_*` 事件會被靜默丟棄。
- **建議**：在 `joinRoom()` 時就把所有 `roomEvents` 的 controller 建好。

### [ ] #E Realtime topic 同時接受 room code 與 channel_id

- **檔案**：`supabase/migrations/20260812120002_harden_room_lifecycle.sql`
- **問題**：`cotime_book_private.can_access_room_topic()` 同時授權
  `cotime_book:room:<code>` 與 `cotime_book:room:<channel_id>`，而 client 只用 code。
  因為 room code 是永久保留不重用的（`room_code_reservations`），目前不會跨房洩漏，
  但 `channel_id` 這層額外隔離等於沒有作用。
- **建議**：要嘛讓 client 改用 `channel_id`（`Room.channelId` 已經有了，
  `PresenceNotifier.joinRoom` 的 `roomTopicId` 參數也已經備好，只是 lobby 沒傳），
  然後把 code-based topic 從授權函式拿掉；要嘛就把 `channel_id` 這條路徑刪掉。

### [ ] #F App 短暫 inactive 就會把 `is_reading` 打掉

- **檔案**：`lib/app.dart`、`lib/providers/presence_provider.dart`
- **問題**：`didChangeAppLifecycleState` 把 `resumed` 以外的狀態都視為不活躍。
  Android 在下拉通知列、跳系統彈窗、甚至某些轉場時都會送 `inactive`，
  於是 Presence 瞬間變成 `is_reading: false`，同房其他人若正好在 confirming 階段
  就會被取消翻頁。
- **建議**：只對 `paused` / `detached` 反應，或對 `inactive` 加一個短去抖動。
