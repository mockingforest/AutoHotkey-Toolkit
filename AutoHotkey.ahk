#Requires AutoHotkey v2.0

; ============================================================
; 【0. ユーザー設定：連射速度などをここで調整してください】
; ============================================================
; 数字（ミリ秒）を小さくすると速く、大きくすると遅くなります。
; 20 = 秒間50回、 33 = 秒間30回、 50 = 秒間20回 が目安です。
global R_Interval := 25			; 左クリック長押し時の連射間隔
global AFK_Interval := 25		; Shift+ScrollLock（放置モード）の連射間隔

; 2秒間の入力上限(デフォルト 70)
A_MaxHotkeysPerInterval := 200

; メニュース表示のマウスカーソルの遊び(px)
global MousePlay_px := 5

; 左ボタンを離した後のコピー受付時間（ミリ秒）
global L_GracePeriod := 300

; --- マウス操作（右左クリック等）を無効化するアプリの設定 ---
; ここに登録したアプリがアクティブな時は、セクション3の特殊操作を無効化します。
IsMouseComboExcluded() => WinActive("ahk_exe dummy_dummy_dummy.exe")
					or WinActive("ahk_exe RLogin.exe")
					or WinActive("ahk_exe Super Jigsaw Puzzle Generations.exe")
					; or WinActive("ahk_exe notepad.exe")
					; or WinActive("ahk_exe excel.exe")
					; or WinActive("ahk_exe code.exe")		; 必要なら ; を消す

; ============================================================
; 【1. 全体設定 : スクリプト全体の動作ルール】
; ============================================================
; --- システム挙動の設定 ---
SetTitleMatchMode 2		; ウィンドウタイトルのどこかにファイル名があれば一致とみなす
#UseHook True			; すべてのホットキーにフックを強制（横取り権限を強める）
InstallMouseHook		; マウスフックの導入
SetKeyDelay -1			; キー送信間のディレイ（待ち時間）をゼロにして送信速度を最速にする
SetWinDelay -1			; ウィンドウ操作時のディレイ（待ち時間）をゼロにして追従性を上げる

; --- 変数の初期化 ---
global isPasted := false		; 右クリックメニューの表示抑制フラグ
global isCopying := false		; コピー中かどうかの判断フラグ（踏切）
global isSearchCopy := false    ; 検索時のコピー重複を防ぐフラグ
global x1 := 0, y1 := 0			; マウス座標の記録
global lx1 := 0, ly1 := 0		; 左クリック開始時の座標
global wasDragging := false		; ドラッグした時のフラグ
global lastLUpTime := 0			; 左クリックを離した時刻の記録
global AFK_Active := false		; 放置モードの状態管理
global Selecting := false		; ターゲット選択モードの管理
global AFK_Target := ""			; 放置連打の対象キー
global LastRButtonDownTime := 0 ; 右クリックの連打速度計測用フラグ
global IsRightDragging := false ; 右ドラッグ中かどうかのフラグ

; --- PC環境適応（RAlt代用） ---
; 日本語配列のキーボードでは「無変換」を「右Alt」として扱う
; vk1D::RAlt

; --- 左ボタンを押した瞬間（座標を記録） ---
~LButton:: {
	global lx1, ly1, wasDragging
	MouseGetPos(&lx1, &ly1)		; 「ここから始まったぞ」と記録
	wasDragging := false		; まだ動いていないので一旦リセット
}

; --- 左ボタン離脱時刻の記録（ドラッグ判定 ＆ 3-1の判定用） ---
~LButton Up:: {
	global lastLUpTime, lx1, ly1, wasDragging
	lastLUpTime := A_TickCount

	MouseGetPos(&lx2, &ly2)
	; 5ピクセル以上動いていたら「これはドラッグ（選択）したな！」と判定
	if (Abs(lx1 - lx2) > 5 or Abs(ly1 - ly2) > 5)
		wasDragging := true
}


; ============================================================
; 【2. メイン設定 : ショートカットや便利機能】（右Alt単体制御版）
; ============================================================

; --- 自動リロード : このスクリプトを編集して保存(Ctrl+S)すると即反映 ---
#HotIf WinActive(A_ScriptName)
	~^s::
	{
		Sleep 200
		Reload
	}
#HotIf


; --- 右Alt単体の挙動をAHKで完全にロックする ---
$*RAlt::
{
	KeyWait "RAlt"
}


; --- 右Altが物理的に「押しっぱなし」の時だけ有効になる特殊レイヤー ---
#HotIf GetKeyState("RAlt", "P")

	; 「右Alt + S」：Google検索
	*s:: GoogleSearch()

	; 「右Alt + D」：基本の日付のみ
	*d:: InsertDate(1)

	; 「右Alt + Shift + D」：詳細な日付
	*+d:: InsertDate(2)

	; 「右Alt + Ctrl + D」：日付を入力してそのまま確定 (Enter)
	*^d::
	{
		InsertDate(1)
		Send("{Enter}")
	}

	; 「右Alt + Ctrl + Shift + D」：詳細を入力してそのまま確定 (Enter)
	*^+d::
	{
		InsertDate(2)
		Send("{Enter}")
	}

#HotIf

; --- 【最重要】上記以外のすべてのキー（Enter、F4など）を通常Altとして動かす ---
; 右Altを通常の左Alt（LAlt）としてそのままWindowsに認識させます。
; AHKが一切の邪魔をしないため、右Alt+Enterでプロパティが100%確実に開きます。
RAlt::LAlt

; --- 緊急停止 ＆ スクリプト再読み込み ---
*Pause::
{
	Critical "On"  ; 連射やループ処理中でも最優先で割り込む
	Suspend False  ; 一時停止（サスペンド）になっていても解除
	Reload         ; スクリプトを即座に再読み込みしてリセット
}


; ============================================================
; 【3. マウス操作 ＆ クリック連射】（完全版）
; ============================================================

; --- 連射・放置解除：ランプが消えるか、放置モードが動いていれば停止 ---
~ScrollLock:: {
	global AFK_Active
	if !GetKeyState("ScrollLock", "T") or AFK_Active {
		StopAFK()
	}
}

; --- 連射モード時 (ScrollLock点灯中) の処理 ---
#HotIf GetKeyState("ScrollLock", "T") and !Selecting
	; 右クリックは最速反応（遊びなし）
	$RButton:: {
		global isPasted := false
		Click "Right Down"
		KeyWait "RButton"
		Click "Right Up"
	}

	; 左ボタン連打
	~LButton:: {
		global R_Interval
		while GetKeyState("LButton", "P") {
			Click
			Sleep R_Interval
		}
	}

	; その他の連打
	~MButton::      RapidFireKey("MButton")
	~XButton1::     RapidFireKey("XButton1")
	~XButton2::     RapidFireKey("XButton2")
	~Space::        RapidFireKey("Space")
#HotIf


; --- 通常モード時 (ScrollLock消灯中) の処理 ---
; ※ セクション0で定義した「除外アプリ」ではない時だけ動作します
#HotIf !GetKeyState("ScrollLock", "T") and !Selecting and !IsMouseComboExcluded()

; 3-1. 【右ボタン全般】

; 3-1-1. 【左ボタン押下時：メニュー遮断・短押しコピー/長押し検索】
#HotIf GetKeyState("LButton", "P")

$RButton::
{
	; 0.25秒間、右ボタンが押し続けられるか監視
	isHold := !KeyWait("RButton", "T0.25")

	if (isHold)
	{
		; --- 長押し（0.25秒以上）：Google検索 ---
		global isPasted := true
		global isSearchCopy := true

		clipSaved := A_Clipboard
		A_Clipboard := ""
		DoCopy()

		if ClipWait(0.25)
		{
			GoogleSearch()
		}
		else
		{
			A_Clipboard := clipSaved
		}
	}
	else
	{
		; --- 短押し（0.25秒未満）：コピー ---
		global isPasted := true
		global isSearchCopy := true
		DoCopy()
	}

	; 指が離れるまで待機（OSにRButton Upを渡さずメニュー遮断）
	KeyWait("RButton")
	return
}

#HotIf  ; 条件解除


; 3-1-2. 【通常時：ドラッグ・右押し＋左押し貼り付け等】
$RButton::
{
	global x1, y1, LastRButtonDownTime, IsRightDragging, isPasted, lastLUpTime, L_GracePeriod, wasDragging, isSearchCopy
	isPasted := false
	IsRightDragging := false
	isSearchCopy := false

	MouseGetPos(&x1, &y1)

	currentRTime := A_TickCount
	timeSinceLastRDown := currentRTime - LastRButtonDownTime
	LastRButtonDownTime := currentRTime

	; --- 【フラグ管理】右ボタンが物理的に「押されている間」状態を監視 ---
	while GetKeyState("RButton", "P")
	{
		; 右を押しながら「左ボタン」が押されたら（コピペコンボ）
		if GetKeyState("LButton", "P")
		{
			isPasted := true

			; --- Google スプレッドシートがアクティブな場合の個別分岐 ---
			if (WinActive("Google スプレッドシート") or WinActive("Google Sheets"))
			{
				Send "#v"
			}
			else
			{
				Send "^v"
			}

			static LastLClick := 0
			if (A_TickCount - LastLClick < 300)
			{
				Sleep 10
				Send "{Enter}"
				LastLClick := 0
			}
			else
			{
				LastLClick := A_Clipboard != "" ? A_TickCount : 0
			}

			KeyWait("RButton")
			return
		}

		; まだドラッグフラグが立っていない場合のみ、距離を確認
		if (!IsRightDragging)
		{
			MouseGetPos(&x2, &y2)
			if (Abs(x1 - x2) > MousePlay_px or Abs(y1 - y2) > MousePlay_px)
			{
				IsRightDragging := true
				Click("Right Down")
			}
		}
		Sleep 10
	}

	; 指を離した時点で「貼り付け」も「ドラッグ」もしていなければ、通常の右クリックを発行
	if (!isPasted and !IsRightDragging)
	{
		Click("Right")
	}
	else if (IsRightDragging)
	{
		Click("Right Up")
	}
}

; 3-2 【ズーム一式】右ボタン押しっぱなし ＋ ホイール操作
#HotIf !GetKeyState("ScrollLock", "T") and GetKeyState("RButton", "P")
	; ホイール上でズームイン (Ctrl + WheelUp)
	*WheelUp::
	{
		global isPasted := true
		Send("^{WheelUp}")
	}

	; ホイール下でズームアウト (Ctrl + WheelDown)
	*WheelDown::
	{
		global isPasted := true
		Send("^{WheelDown}")
	}

	; ホイールクリックでズームリセット (Ctrl + 0)
	*MButton::
	{
		global isPasted := true
		Send("^0")
	}
#HotIf


; --- 3-3. 【ホイール左右スクロール】通常時・連射時共通（除外アプリ以外で動作） ---
; チルト操作（ホイール左右傾け）に対応していない、ごく一部の古いアプリや海外製のアプリで、
; 横スクロール（Shift＋上下ホイール）に変換する
/*
#HotIf !Selecting and !IsMouseComboExcluded()
	WheelLeft::
	{
		Send "{Shift Down}{WheelUp}{Shift Up}"
		return
	}

	WheelRight::
	{
		Send "{Shift Down}{WheelDown}{Shift Up}"
		return
	}
#HotIf
*/


; 3-4. 【放置連射】Shift + ScrollLock（ON/OFF 切り替え）
+ScrollLock:: {
	global AFK_Active, Selecting
	if !AFK_Active {
		SetScrollLockState "On"
		global Selecting := true
		ToolTip "ターゲットを選択してください..."

		ih := InputHook("L1 T5"), ih.KeyOpt("{All}", "E")
		ih.OnEnd := (ih) => (ih.EndReason = "EndKey" ? SetAFKTarget(ih.EndKey) : (ih.Input != "" ? SetAFKTarget(ih.Input) : ""))
		ih.Start()
		SetTimer(CheckTimeout, 5000)
	} else {
		StopAFK()
	}
}

; ターゲット選択用
#HotIf Selecting
	~$LButton:: SetAFKTarget("LButton")
	~$RButton:: SetAFKTarget("RButton")
	~$MButton:: SetAFKTarget("MButton")
	~$XButton1:: SetAFKTarget("XButton1")
	~$XButton2:: SetAFKTarget("XButton2")
#HotIf


; ============================================================
; 【4. 関数定義 : スクリプトの心臓部】
; ============================================================

; --- 4-1. 【コピーの核心部：DoCopy】 ---
; 「空振り」を許さない、粘り強いコピー処理の司令塔。
; ※事前消去(A_Clipboard:="")を廃止し、実行前後のバイナリ直接比較によりデータ消去事故を防ぐ仕様へ改修
DoCopy() {
	global isCopying        ; 貼り付け(3-2)側に「今コピー中だよ」と伝えるための看板
	isCopying := true       ; 【踏切：開始】

	; 1. 現在のクリップボードを一時避難（画像なども含めて丸ごと保存）
	local beforeData := ClipboardAll()

	; 2. センサーを初期化（一度空にする）
	; → 事前消去によるデータ消失を防ぐため消去処理は廃止し、直接Ctrl+Cを送信

	; 3. コピー命令(Ctrl+C)を送信
	Send "^c"
	Sleep 100 ; アプリ側のデータ格納処理を考慮して待機

	; 4. 【粘り強い監視ループ】
	; 実行後のクリップボード生データを取得
	local afterData := ClipboardAll()

	; 5. 判定とアクション
	if (afterData.Size == 0) {
		; 何も選択されていない等の理由で空の場合
		ToolTip "No Data Selected"
		SetTimer(() => ToolTip(), -1000)
	}
	else if (HasClipDataChanged(beforeData, afterData) == false) {
		; 変化なし（すでに同じデータがクリップボードに入っている）場合
		SoundBeep 800, 50
		ToolTip "Already in Clipboard"
		SetTimer(() => ToolTip(), -1000)
	}
	else {
		; 成功時に音で通知
		SoundBeep 1000, 80
		ToolTip "Copy!"
		SetTimer(() => ToolTip(), -1000)
	}

	global isCopying := false       ; 【踏切：終了】
}

; --- クリップボード生データ（ClipboardAll）の一致判定用ヘルパー関数 ---
HasClipDataChanged(data1, data2) {
	if (data1.Size != data2.Size)
		return true

	if (data1.Size == 0)
		return false

	; メモリ領域を直接バイナリ比較（0以外で不一致＝データ変更あり）
	return DllCall("ntdll\RtlCompareMemory", "Ptr", data1.Ptr, "Ptr", data2.Ptr, "UInt", data1.Size, "UPtr") != data1.Size
}


; --- 4-2. 【Google検索】 ---
; 概要：選択中のテキスト、または入力ボックスからGoogle検索を実行します。
; 特徴：Braveのアクティブなタブの「右隣」に検索結果を展開します。
GoogleSearch() {
	global isSearchCopy

	; --- [1] 現在のクリップボードを一時保存 ---
	; 画像などが入っていても壊さないよう ClipboardAll を使用
	local SavedClip := ClipboardAll()

	; 左→右ダブルクリック時のCtrl+Cの重複（2回連打によるDeepL暴発）を防ぐため、
	; クリップボードが空（直前のコピー処理がない）の場合のみ新規コピーを実行する
	if (!isSearchCopy and A_Clipboard == "") {
		Send "^c"

		; コピーに失敗（何も選択していない）した場合は、入力ボックスを表示
		if !ClipWait(0.2) {
			IB := InputBox("検索ワードを入力してください", "Google検索", "w300 h100")

			; キャンセルされた場合はクリップボードを戻して終了
			if (IB.Result = "Cancel") {
				A_Clipboard := SavedClip
				return
			}
			A_Clipboard := IB.Value
		}
	}

	; --- [3] 検索の実行 ---
	; 検索ワードが空でない場合のみ、Braveを操作
	if (A_Clipboard != "") {
		; 検索ワードをURL形式に強制変換（ドット等によるURL誤認を防止）
		local search_url := "https://www.google.com/search?q=" . A_Clipboard

		; Braveが未起動なら起動し、最前面に持ってくる
		if !WinExist("ahk_exe brave.exe") {
			Run "brave.exe"
		}
		WinActivate "ahk_exe brave.exe"

		; ウィンドウが反応するまで最大2秒待機
		if WinWaitActive("ahk_exe brave.exe", , 2) {
			; A. 右隣に新しいタブを作成（独自のショートカット）
			Send "^!+t"			; [Ctrl] + [Alt] + [Shift] + [T] (右隣に新規タブ)
			Sleep 250			; タブ作成のラグを考慮して少し待つ

; B. アドレスバーへURLを流し込む
			Send "^l"			; URL欄にフォーカス
			Sleep 50

			A_Clipboard := search_url
			Sleep 50
			Send "^v"			; URLを貼り付け
			Sleep 50			; 貼り付け完了をわずかに待つ
			Send "{Enter}"		; 確実にEnterを送信
		}
	}

	; --- [4] 後処理 ---
	; Windows側の処理を待ってから、元のクリップボードを復元
	Sleep 500
	A_Clipboard := SavedClip
	isSearchCopy := false		; フラグをリセット
}


; --- 4-3. 日付入力 ---
InsertDate(type) {
	local saved := ClipboardAll()
	local fmt := (type == 1) ? "yyyyMMdd" : (type == 2) ? "yyyyMMdd-HHmmss" : type

	A_Clipboard := " - " . FormatTime(, fmt)
	Send "^v"

	Sleep 100
	A_Clipboard := saved
}


; --- 4-4. 【放置モード：AFK関連】 ---
; 「ターゲット選択」から「自動連打」までを管理する一連のロジック

; 【停止】放置モードを終わらせ、ランプを消す
StopAFK() {
	global AFK_Active := false
	SetScrollLockState "Off"		; ScrollLockのランプを物理的に消灯
	SetTimer(AFK_Loop, 0)			; 連打ループのタイマーを停止
	ToolTip "連打停止"
	SetTimer(() => ToolTip(), -1000)
}

; 【セット】狙ったボタンやキーを連打ターゲットに登録する
SetAFKTarget(key) {
	global AFK_Target, AFK_Active, Selecting, AFK_Interval
	if (!Selecting) {
		return
	}

	global Selecting := false			; ターゲットが確定したので選択モード終了
	global AFK_Target := key			; 選ばれたキーをメモリに保存
	global AFK_Active := true			; 放置フラグをON

	ToolTip "連打開始: " . key
	SetTimer(AFK_Loop, AFK_Interval)	; セクション0の設定速度で連打を開始
	SetTimer(CheckTimeout, 0)			; タイムアウト監視用のタイマーを止める
	SetTimer(() => ToolTip(), -1000)
}

; 【ループ】登録されたキーを機械のように叩き続ける心臓部
AFK_Loop() {
	global AFK_Active, AFK_Target
	if (!AFK_Active) {
		return
	}
	Send "{" . AFK_Target . "}"
}

; 【監視】5秒間何も選ばれなかったら「やる気なし」とみなして解除
CheckTimeout() {
	global Selecting
	if (Selecting) {
		global Selecting := false
		ToolTip "タイムアウト"
		SetTimer(() => ToolTip(), -1000)
	}
}


; --- 4-5. 【連打用関数：RapidFireKey】 ---
; マウスのサイドボタンやSpaceキーなど、あらゆるキーの「押しっぱなし連打」を共通化
RapidFireKey(key) {
	global R_Interval		; セクション0で設定した「連打の鼓動」を参照
	while GetKeyState(key, "P") {
		Click				; 汎用性を高めるため、デフォルトはクリック動作
		Sleep R_Interval
	}
}


; ============================================================
; 【自動サスペンド（完全停止）システム】
; ============================================================
; 画面が切り替わったときに、設定エリア（IsMouseComboExcluded）に登録された
; アプリがアクティブかどうかをチェックし、手動の「Suspend Hotkeys」と同じ状態を自動で切り替えます。
SetTimer CheckWindowForSuspend, 500

CheckWindowForSuspend() {
	; 設定エリアに登録したアプリ（RLoginや追加したゲームなど）がアクティブかどうか
	if IsMouseComboExcluded() {
		; 対象アプリの画面なら、手動で右クリックしたのと同じ「Suspend（一時停止）」をONにする
		if !A_IsSuspended {
			Suspend True
		}
	} else {
		; 対象アプリから離れたら、自動で「Suspend（一時停止）」を解除して元に戻す
		if A_IsSuspended {
			Suspend False
		}
	}
}
