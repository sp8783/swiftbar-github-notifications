# SwiftBar GitHub Notifications

GitHub NotificationsをmacOSのメニューバーに表示するSwiftBarプラグインです。

## 使い方

メニューバーの件数表示をクリックすると通知一覧が開きます。通知の行をクリックすると、対応するGitHubのIssue、Pull Requestなどをブラウザで開きます。

ドロップダウン末尾の「Hide read notifications」または「Show read notifications」をクリックすると、既読通知を表示するか切り替えられます。初期状態では既読通知も表示します。

## セットアップ

1. [SwiftBar](https://swiftbar.app/) をインストールし、Plugin Folderを選びます。例: `~/Documents/SwiftBarPlugins`

2. このリポジトリで、プラグイン本体とGitHubアイコンをPlugin Folderへ配置します。

```sh
PLUGIN_DIR="$HOME/Documents/SwiftBarPlugins"
mkdir -p "$PLUGIN_DIR/.assets"
cp github-notifications.1m.rb "$PLUGIN_DIR/"
cp .assets/github-mark.png "$PLUGIN_DIR/.assets/"
chmod +x "$PLUGIN_DIR/github-notifications.1m.rb"
```

アイコンは `.assets/github-mark.png` に置く必要があります。Plugin Folder直下に置くと、SwiftBarが画像そのものをプラグインとして読み込もうとします。

3. GitHubで **Settings → Developer settings → Personal access tokens → Tokens (classic)** を開き、`notifications` スコープのトークンを作成します。

4. トークンを保存します。

```sh
mkdir -p ~/.config/swiftbar-github-notifications
chmod 700 ~/.config/swiftbar-github-notifications
nano ~/.config/swiftbar-github-notifications/token
chmod 600 ~/.config/swiftbar-github-notifications/token
```

5. SwiftBarを再起動するか、1分待ちます。`0/0` や `3/12` と表示されれば成功です。`GH !` の場合は、クリックすると原因を確認できます。
