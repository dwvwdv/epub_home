# EPUB Home - 架構設計文檔

## 概述
共享 EPUB 閱讀器應用，支援多人同步閱讀體驗。

## 核心功能
1. **EPUB 閱讀器** - 完整的電子書閱讀體驗
2. **房間連線機制** - 本地網絡設備發現與連接（未來支援外部連線）
3. **同步翻頁** - 多設備同步閱讀進度

## 架構設計

### 1. 層次架構
```
┌─────────────────────────────────────┐
│         Presentation Layer          │
│    (Screens, Widgets, Providers)    │
├─────────────────────────────────────┤
│         Business Logic Layer        │
│    (Services, State Management)     │
├─────────────────────────────────────┤
│           Data Layer                │
│    (Models, Local Storage, API)     │
└─────────────────────────────────────┘
```

### 2. 核心模塊

#### 2.1 EPUB 閱讀器模塊
- **EpubService**: EPUB 文件解析與管理
  - 解析 EPUB 文件結構
  - 提取章節內容
  - 管理閱讀進度
  - 支援文字顯示與樣式

#### 2.2 房間連線模塊
- **RoomService**: 房間管理
  - 創建/加入房間
  - 房間狀態管理
  - 用戶管理

- **NetworkService**: 網絡通信
  - 本地網絡設備發現 (mDNS)
  - WebSocket 連接
  - Webhook 集成 (n8n)

- **SyncService**: 同步服務
  - 翻頁同步邏輯
  - 等待所有用戶確認
  - 狀態同步

#### 2.3 數據模型
```dart
// Book Model
class Book {
  String id;
  String title;
  String author;
  String filePath;
  List<Chapter> chapters;
  int currentChapter;
  int currentPage;
}

// Room Model
class Room {
  String id;
  String name;
  String hostId;
  Book book;
  List<User> participants;
  RoomStatus status;
  Map<String, PageStatus> pageStatuses;
}

// User Model
class User {
  String id;
  String name;
  String deviceId;
  bool isHost;
}

// PageStatus
enum PageStatus {
  viewing,      // 正在查看當前頁
  readyToTurn,  // 準備翻頁
  waiting       // 等待其他人
}
```

### 3. 同步翻頁流程

```
用戶A翻頁請求
    │
    ├─→ 發送到 n8n Webhook
    │   (POST /webhook/{roomKey})
    │   Body: { userId, action: "page_turn", page: N }
    │
    ├─→ 本地狀態更新為 "waiting"
    │   顯示等待畫面
    │
    ├─→ Webhook 收集所有用戶狀態
    │   檢查是否所有人都確認翻頁
    │
    └─→ 當所有人確認後
        ├─→ Webhook 返回 200 OK
        ├─→ 所有設備收到通知
        └─→ 同時執行翻頁動作
```

### 4. 技術選型

#### 4.1 EPUB 解析
- **epubx**: EPUB 文件解析
- **flutter_html**: HTML 內容渲染

#### 4.2 網絡通信
- **multicast_dns**: 本地設備發現
- **dio/http**: HTTP 請求
- **WebSocket**: 實時通信（未來）

#### 4.3 狀態管理
- **Provider**: 全局狀態管理
- **GetIt**: 依賴注入

#### 4.4 本地存儲
- **shared_preferences**: 簡單配置存儲
- **sqflite**: 本地數據庫（書籍、歷史記錄）
- **path_provider**: 文件路徑管理

### 5. 目錄結構

```
lib/
├── main.dart                 # 應用入口
├── app.dart                  # App 配置
├── models/                   # 數據模型
│   ├── book.dart
│   ├── room.dart
│   ├── user.dart
│   └── chapter.dart
├── services/                 # 服務層
│   ├── epub_service.dart     # EPUB 解析服務
│   ├── room_service.dart     # 房間管理服務
│   ├── network_service.dart  # 網絡服務
│   ├── sync_service.dart     # 同步服務
│   └── storage_service.dart  # 存儲服務
├── providers/                # 狀態管理
│   ├── book_provider.dart
│   ├── room_provider.dart
│   └── user_provider.dart
├── screens/                  # 畫面
│   ├── home_screen.dart      # 首頁
│   ├── library_screen.dart   # 書庫
│   ├── reader_screen.dart    # 閱讀器
│   ├── room_screen.dart      # 房間管理
│   └── settings_screen.dart  # 設置
├── widgets/                  # 自定義組件
│   ├── epub_reader.dart      # EPUB 閱讀器組件
│   ├── page_turn_overlay.dart # 翻頁等待覆蓋層
│   ├── room_card.dart        # 房間卡片
│   └── book_card.dart        # 書籍卡片
└── utils/                    # 工具類
    ├── constants.dart        # 常量
    ├── logger.dart           # 日誌
    └── di.dart               # 依賴注入配置
```

### 6. API 接口設計

#### 6.1 n8n Webhook API

**翻頁請求**
```
POST https://n8n.lazyrhythm.com/webhook/{roomKey}
Content-Type: application/json

{
  "action": "page_turn",
  "userId": "user-uuid",
  "userName": "張三",
  "currentPage": 42,
  "targetPage": 43,
  "timestamp": "2025-12-19T10:30:00Z"
}
```

**響應（所有人確認後）**
```json
{
  "status": "ready",
  "targetPage": 43,
  "participants": [
    {"userId": "user-1", "confirmed": true},
    {"userId": "user-2", "confirmed": true}
  ]
}
```

**響應（等待中）**
```
HTTP 202 Accepted
{
  "status": "waiting",
  "confirmedUsers": ["user-1"],
  "waitingUsers": ["user-2"]
}
```

### 7. 未來擴展

1. **外部連線支援**
   - WebSocket 服務器
   - 雲端房間管理
   - NAT 穿透

2. **閱讀功能增強**
   - 書籤
   - 筆記
   - 字體調整
   - 夜間模式

3. **社交功能**
   - 語音聊天
   - 即時訊息
   - 閱讀統計

4. **性能優化**
   - 頁面預加載
   - 圖片緩存
   - 離線支援
