# Tomado

A minimalist Pomodoro timer with task management for macOS.

> **Tomado** = **Toma**to + To**do** + **ma**rk**do**wn

## Design Philosophy

**Focus on what matters.** Tomado is built around the idea that productivity tools should get out of your way. No account required, no cloud sync, no distractions—just you and your tasks.

- **Single-window simplicity**: Everything you need is visible at a glance
- **Keyboard-first**: Every action has a shortcut for flow state
- **Research-based**: Timer presets grounded in cognitive science
- **Hierarchical tasks**: Break down work naturally with subtasks
- **Priority-driven**: Three levels (!, !!, !!!) keep decisions simple
- **Local-first**: Your data stays on your machine

## Features

- **Pomodoro Timer**: Work sessions, short breaks, and long breaks with customizable durations
- **Task Management**: Simple task list with priority levels (!, !!, !!!)
- **Subtasks**: Organize tasks hierarchically with drag & drop
- **View Modes**: Toggle between separated view and hierarchy view
- **Keyboard-First**: Comprehensive keyboard shortcuts for all actions
- **Import/Export**: Copy tasks from/to clipboard with indentation support
- **Localization**: English and Japanese support

## Screenshot

![Tomado](docs/screenshot.png)

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘P | Play/Pause timer |
| ⌘D | Complete current task |
| ⌘L | Postpone current task |
| ⌘S | Skip current phase |
| ⌘R | Reset cycle |
| ⌘⇧S | Sort by priority |
| ⌘⇧V | Toggle view mode |
| ⌘⇧T | Toggle timer preset |
| ⌘⇧P | Toggle topmost |
| ⌘⌫ | Delete completed tasks |
| ⌘⇧⌫ | Delete all tasks |
| ⌘V | Import from clipboard |
| ⌘C | Export to clipboard |
| Enter | Add task (!!) |
| ⇧Enter | Add task (!) |
| ⌘Enter | Add task (!!!) |

## Task Priority

- `!` Low priority (gray)
- `!!` Medium priority (blue) - default
- `!!!` High priority (red)

## Timer Presets

This app offers two timer presets inspired by some research on effort regulation and structured break-taking.

### 🐇 Short Focus Mode (12 min + 3 min break)

Research suggests that people naturally tend to switch tasks approximately every 12 minutes (González & Mark, 2004; Mark et al., 2005). Biwer et al. (2023) compared short systematic breaks (12 min work / 3 min break), long systematic breaks (24 min work / 6 min break), and self-regulated breaks. Both systematic conditions reduced fatigue and improved concentration compared to self-regulated breaks. Notably, the short-interval condition showed favorable trends over the long-interval condition across most indicators, suggesting potential benefits of aligning break timing with natural task-switching rhythms.

### 🐢 Deep Focus Mode (35 min + 10 min break)

For cognitively demanding tasks requiring sustained attention, Ogut (2025) reviewed the literature on the Pomodoro Technique and proposed extended intervals of 35 minutes of focused work followed by 10-minute breaks. While this specific configuration awaits direct experimental validation, it is grounded in cognitive load theory and aims to support deeper engagement without premature interruption.

**References:**

- Biwer, F., Wiradhany, W., oude Egbrink, M. G. A., & de Bruin, A. B. H. (2023). Understanding effort regulation: Comparing 'Pomodoro' breaks and self-regulated breaks. *British Journal of Educational Psychology*, 93(S2), 353–367. https://doi.org/10.1111/bjep.12593
- González, V. M., & Mark, G. (2004). "Constant, constant, multi-tasking craziness": Managing multiple working spheres. *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems*, 113–120. https://doi.org/10.1145/985692.985707
- Mark, G., González, V. M., & Harris, J. (2005). No task left behind? Examining the nature of fragmented work. *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems*, 321–330. https://doi.org/10.1145/1054972.1055017
- Ogut, E. (2025). Assessing the efficacy of the Pomodoro technique in enhancing anatomy lesson retention during study sessions: A scoping review. *BMC Medical Education*, 25(1), 1440. https://doi.org/10.1186/s12909-025-08001-0

## Import/Export Format

Tasks use Markdown checkbox format. Priority is indicated by trailing `!` marks.

**Import formats:**
```markdown
- [ ] Task with medium priority
- [ ] High priority task !!!
- [x] Completed task
  - [ ] Subtask (indented)
```

With "Allow list format" enabled in settings:
```markdown
- Task without checkbox
1. Numbered list item
* Asterisk list item
```

**Export format:**

```markdown
- [ ] Task !!
  - [ ] Subtask
- [x] Completed task !!!
```

Note: Subtasks inherit priority from their parent (no `!` marks).

Indent style (spaces/tab) is configurable in settings.

## Requirements

- macOS 14.0 or later

## Installation

1. Download the latest release
2. Move Tomado.app to your Applications folder
3. Launch Tomado

## Building from Source

1. Clone the repository
2. Open `Tomado.xcodeproj` in Xcode
3. Build and run (⌘R)

## License

MIT License

---

# Tomado

macOS向けのミニマリストなポモドーロタイマー＆タスク管理アプリ。

> **Tomado** = **Toma**to + To**do** + **ma**rk**do**wn

## 設計思想

**本質に集中する。** Tomadoは、生産性ツールは邪魔にならないべきという考えで作られています。アカウント不要、クラウド同期なし、余計な機能なし—あなたとタスクだけ。

- **シングルウィンドウ**: 必要な情報は一目で把握
- **キーボードファースト**: すべての操作にショートカット
- **研究ベース**: 認知科学に基づいたタイマープリセット
- **階層タスク**: サブタスクで自然に作業を分割
- **優先度駆動**: 3段階（!, !!, !!!）でシンプルな判断
- **ローカルファースト**: データは自分のマシンに

## 機能

- **ポモドーロタイマー**: 作業・短い休憩・長い休憩のカスタマイズ可能なタイマー
- **タスク管理**: 優先度付き（!, !!, !!!）のシンプルなタスクリスト
- **サブタスク**: ドラッグ＆ドロップで階層的にタスクを整理
- **ビューモード**: 分離ビューと階層ビューを切り替え
- **キーボード操作**: すべての操作にショートカットキー対応
- **インポート/エクスポート**: クリップボード経由でタスクをコピー（インデント対応）
- **多言語対応**: 英語・日本語に対応

## スクリーンショット

![Tomado](docs/screenshot.png)

## キーボードショートカット

| ショートカット | 操作 |
|---------------|------|
| ⌘P | 再生/停止 |
| ⌘D | 現在のタスクを完了 |
| ⌘L | 現在のタスクを後回し |
| ⌘S | フェーズをスキップ |
| ⌘R | サイクルをリセット |
| ⌘⇧S | 優先度順にソート |
| ⌘⇧V | ビューモード切替 |
| ⌘⇧T | タイマープリセット切替 |
| ⌘⇧P | 最前面固定切替 |
| ⌘⌫ | 完了タスクを削除 |
| ⌘⇧⌫ | すべてのタスクを削除 |
| ⌘V | クリップボードからインポート |
| ⌘C | クリップボードにエクスポート |
| Enter | タスク追加 (!!) |
| ⇧Enter | タスク追加 (!) |
| ⌘Enter | タスク追加 (!!!) |

## タスクの優先度

- `!` 低優先度（グレー）
- `!!` 中優先度（青）- デフォルト
- `!!!` 高優先度（赤）

## タイマープリセット

このアプリは、努力調節と構造化された休憩に関するいくつかの研究に基づいた2つのタイマープリセットを提供します。

### 🐇 ショートフォーカスモード（12分 + 3分休憩）

研究によると、人は約12分ごとにタスクを切り替える傾向があります（González & Mark, 2004; Mark et al., 2005）。Biwer et al. (2023) は、短い体系的休憩（12分作業／3分休憩）、長い体系的休憩（24分作業／6分休憩）、自己調整休憩を比較しました。両方の体系的条件は、自己調整休憩と比較して疲労を軽減し集中力を向上させました。特に短い間隔の条件は、ほとんどの指標で長い間隔の条件より良好な傾向を示し、自然なタスク切り替えリズムに休憩タイミングを合わせることの潜在的な利点を示唆しています。

### 🐢 ディープフォーカスモード（35分 + 10分休憩）

持続的な注意を必要とする認知的に要求の高いタスクに対して、Ogut (2025) はポモドーロ・テクニックに関する文献をレビューし、35分の集中作業と10分の休憩という拡張された間隔を提案しました。この特定の構成は直接的な実験的検証を待っていますが、認知負荷理論に基づいており、早すぎる中断なしにより深い取り組みをサポートすることを目的としています。

**参考文献：**

- Biwer, F., Wiradhany, W., oude Egbrink, M. G. A., & de Bruin, A. B. H. (2023). Understanding effort regulation: Comparing 'Pomodoro' breaks and self-regulated breaks. *British Journal of Educational Psychology*, 93(S2), 353–367.
- González, V. M., & Mark, G. (2004). "Constant, constant, multi-tasking craziness": Managing multiple working spheres. *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems*, 113–120.
- Mark, G., González, V. M., & Harris, J. (2005). No task left behind? Examining the nature of fragmented work. *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems*, 321–330.
- Ogut, E. (2025). Assessing the efficacy of the Pomodoro technique in enhancing anatomy lesson retention during study sessions: A scoping review. *BMC Medical Education*, 25(1), 1440.

## インポート/エクスポート形式

Markdownチェックボックス形式を使用。優先度は末尾の `!` で指定。

**インポート形式：**

```markdown
- [ ] 中優先度のタスク
- [ ] 高優先度タスク !!!
- [x] 完了したタスク
  - [ ] サブタスク（インデント）
```

設定で「リスト形式を許可」を有効にすると：

```markdown
- チェックボックスなしのタスク
1. 番号付きリスト
* アスタリスクリスト
```

**エクスポート形式：**

```markdown
- [ ] タスク !!
  - [ ] サブタスク
- [x] 完了タスク !!!
```

※サブタスクは親の優先度を継承（`!` マークなし）

インデントスタイル（スペース/タブ）は設定で変更可能。

## 動作環境

- macOS 14.0以降

## インストール

1. 最新のリリースをダウンロード
2. Tomado.appをアプリケーションフォルダに移動
3. Tomadoを起動

## ソースからビルド

1. リポジトリをクローン
2. `Tomado.xcodeproj`をXcodeで開く
3. ビルドして実行（⌘R）

## ライセンス

MIT License
