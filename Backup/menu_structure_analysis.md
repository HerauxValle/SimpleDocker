# simpleDocker TUI Menu Tree

## 0. Initial Launch (Image Selection)
*Appears if no default image is configured or mounted.*
* **◈ Select existing image** *(Opens `yazi` file manager to pick a `.img` file)*
* **◈ Create new image**
  * `Prompt:` Image name
  * `Prompt:` Max size in GB
  * `Prompt:` Select directory *(Opens `yazi`)*
* **<Detected images list>** *(Auto-detected `.img` files in the home directory)*

---

## 1. Main Menu (`main_menu`)
* **◈ Containers** ➔ *[Go to 1.1]*
* **▶ Groups** ➔ *[Go to 1.2]*
* **◈ Blueprints** ➔ *[Go to 1.3]*
* **? Other** *(Help / Settings / Tools)* ➔ *[Go to 1.4]*
* **× Quit** ➔ *[Go to 1.5]*

---

### 1.1 Containers (`_containers_submenu`)
* **<List of existing containers>** ➔ *[Go to 1.1.1]*
* **+ New container**
  * **Install from blueprint**
    * `<List of standard blueprints>` ➔ `Prompt:` Container name
    * `<List of persistent blueprints>` ➔ `Prompt:` Container name
    * `<List of imported blueprints>` ➔ `Prompt:` Container name
  * **Clone existing container**
    * `<List of installed containers>`
      * **Current state** ➔ `Prompt:` Name for clone
      * **Post-Installation** ➔ `Prompt:` Name for clone
      * **<Other Backup Snapshots>** ➔ `Prompt:` Name for clone
      * **← Back**
  * **← Back**
* **← Back**

#### 1.1.1 Container Submenu (`_container_submenu`)
*Dynamic options based on container state (Running, Stopped, Not Installed, Installing):*
* *If currently Installing:*
  * **→ Attach to installation** *(Attaches to tmux session)*
  * **✓ Finish installation** *(Appears when install script finishes)*
* *If Running:*
  * **■ Stop**
  * **↺ Restart**
  * **→ Attach**
  * **⊕ Open in**
    * **⊕ Browser** *(Opens container URL in host web browser)*
    * **⊞ Show QR code** *(Requires QRencode plugin and 'public' exposure)*
    * **◧ File manager** *(Opens host file explorer)*
    * **◉ Terminal** *(Opens bash session inside container directory)*
    * **← Back**
  * **≡ View log**
  * **<Custom Actions>** *(Defined in `service.json` [actions] block)*
  * **<Cron Jobs>** *(Defined in `service.json` [cron] block - select to attach to cron log)*
* *If Installed (Stopped):*
  * **▶ Start**
    * **▶ Start and show live output**
    * **Start in the background**
  * **⊕ Open in** *(Same as above)*
  * **◈ Backups** ➔ *[Go to 1.1.1.1]*
  * **◧ Profiles** *(Persistent Storage)* ➔ *[Go to 1.4.1]*
  * **◦ Edit toml** *(Opens blueprint source in `$EDITOR`)*
  * **⬆ Updates** *(Appears if updates are detected)*
    * **Ubuntu base update**
    * **Package updates** *(apt, pip, npm, git)*
    * **Blueprint configuration changes**
  * **○ Uninstall** *(Deletes installation subvolume, keeps storage)*
* *If Not Installed:*
  * **↓ Install**
  * **◦ Edit toml**
  * **✎ Rename** ➔ `Prompt:` New name
  * **× Remove** *(Deletes container entry entirely)*
* **← Back**

##### 1.1.1.1 Container Backups Menu (`_container_backups_menu`)
* **<List of Automatic backups>**
  * **Restore**
  * **Create clone** ➔ `Prompt:` Name for clone
  * **Delete**
* **<List of Manual backups>** *(Same options as Automatic)*
* **+ Create manual backup** ➔ `Prompt:` Backup name
* **× Remove all backups**
  * **All automatic**
  * **All manual**
  * **All (automatic + manual)**
* **← Back**

---

### 1.2 Groups (`_groups_menu`)
* **<List of existing groups>** ➔ *[Go to 1.2.1]*
* **+ New group** ➔ `Prompt:` Group name
* **← Back**

#### 1.2.1 Group Submenu (`_group_submenu`)
* **▶ Start group**
* **■ Stop group** *(Appears if running)*
* **≡ Edit name/desc** ➔ `Prompts:` Group name, Description
* **× Delete group**
* **<Sequence List>** *(List of containers and wait steps in order)*
  * **Add before** ➔ Pick: `Container` or `Wait (seconds)`
  * **Edit** ➔ Pick: `Container` or `Wait (seconds)`
  * **Add after** ➔ Pick: `Container` or `Wait (seconds)`
  * **Remove**
* **+ Add step** ➔ Pick: `Container` or `Wait (seconds)`
* **← Back**

---

### 1.3 Blueprints (`_blueprints_submenu`)
* **<List of User Blueprints>** * **◦ Edit** *(Opens in `$EDITOR`)*
  * **✎ Rename** ➔ `Prompt:` New name
  * **× Delete**
* **<List of Persistent Blueprints>** *(Built-in, read-only preview)*
* **<List of Imported Blueprints>** *(Auto-detected, read-only preview)*
* **+ New blueprint** ➔ `Prompt:` Blueprint name
* **← Back**

---

### 1.4 Other (`_help_menu`)
* **◈ Profiles & data** ➔ *[Go to 1.4.1]*
* **◈ Backups** *(Select a container to manage its backups)*
* **◈ Blueprints** ➔ *[Go to 1.4.2]*
* **◈ Ubuntu base** ➔ *[Go to 1.4.3]*
* **◈ Caddy** ➔ *[Go to 1.4.4]*
* **◈ QRencode**
  * **↓ Install** *(Or ↑ Update / × Uninstall if installed)*
* **◈ Active processes**
  * **<List of running tmux sessions/processes>** ➔ Select to Kill
* **◈ Resource limits**
  * **<List of Containers>**
    * **Toggle cgroups on/off**
    * **CPU quota** ➔ `Prompt:` Value (e.g., 200%)
    * **Memory max** ➔ `Prompt:` Value (e.g., 8G)
    * **Memory+swap** ➔ `Prompt:` Value
    * **CPU weight** ➔ `Prompt:` Value (1-10000)
    * **← Back**
* **≡ Blueprint preset** *(Read-only template view)*
* **≡ View logs**
  * **<List of .log files>** *(Select to read)*
* **⊘ Clear cache**
* **▷ Resize image** ➔ `Prompt:` New size in GB
* **◈ Manage Encryption** ➔ *[Go to 1.4.5]*
* **× Delete image file** *(Permanently deletes the active .img file)*
* **← Back**

#### 1.4.1 Persistent Storage (`_persistent_storage_menu`)
* **<List of Storage Profiles>** *(Shows size, state, default container)*
  * **☆ Unset default** / **★ Set as default**
  * **✎ Rename** ➔ `Prompt:` New name
  * **× Delete**
* **↑ Export** *(Or "Export running")*
  * **Select profiles to export** ➔ `Prompt:` Target directory ➔ `Prompt:` Archive filename
* **↓ Import** *(Or "Import running")*
  * **Select .tar.zst archive** *(via yazi)*
* **← Back**

#### 1.4.2 Blueprint Settings (`_blueprints_settings_menu`)
* **◈ Persistent blueprints** *(Toggles built-in visibility Enabled/Disabled)*
* **◈ Autodetect blueprints** *(Cycles: Home → Root → Everywhere → Custom → Disabled)*
* **<List of Custom Paths>** *(Select to remove path - visible if Custom mode)*
* **+ Add path** *(via yazi - visible if Custom mode)*
* **← Back**

#### 1.4.3 Ubuntu Base (`_ubuntu_menu`)
* **◈ Updates**
  * **◈ Sync default pkgs**
  * **◈ Update all pkgs**
  * **← Back**
* **◈ Uninstall Ubuntu base**
* **<List of Default packages>** *(Protected)*
* **<List of System packages>** *(Protected)*
* **<List of User Packages>** *(Select to remove)*
* **+ Add package** ➔ `Prompt:` Package name ➔ `Prompt:` Version
* **← Back**

#### 1.4.4 Reverse Proxy / Caddy (`_proxy_menu`)
* **◈ Caddy + mDNS** * *If not installed:* Installs Caddy
  * *If installed:* **Reinstall / update**, **Uninstall**, **View log**, **View Caddyfile**, **Reset proxy config**
* **◈ Running** *(Toggles Start/Stop)*
* **◈ Autostart** *(Toggles On/Off)*
* **<List of Custom Routes>**
  * **Change URL** ➔ `Prompt:` New URL
  * **Change container** ➔ Select from container list
  * **Toggle HTTPS**
  * **Remove**
* **+ Add URL**
  * Select Container ➔ `Prompt:` URL ➔ Select Protocol (`http`, `https`)
* **<List of Installed Containers>** *(Port exposure toggles)*
  * Cycles between: `isolated` → `localhost` → `public`
* **← Back**

#### 1.4.5 Manage Encryption (`_enc_menu`)
* **◈ System Agnostic** *(Toggles Enabled/Disabled - Allows opening without verified system)*
* **◈ Auto-Unlock** *(Toggles Enabled/Disabled - Uses machine-id)*
* **◈ Reset Auth Token** ➔ `Prompt:` Existing passphrase
* **<List of Verified Systems>**
  * **Unauthorize**
* **+ Verify this system** *(Caches current machine to Auto-Unlock)*
* **<List of User Passkeys>**
  * **Rename** ➔ `Prompt:` New name
  * **Remove**
* **+ Add Key**
  * **name, pbkdf, ram, threads, iter-ms, cipher, key-bits, hash, sector** *(Select any to modify value)*
  * **▷ Continue** ➔ `Prompt:` New passphrase ➔ `Prompt:` Confirm
  * **× Cancel**
* **← Back**

---

### 1.5 Quit (`_quit_menu`)
* **Quit** *(Exits TUI, background containers keep running)*
* **⊙ Detach** *(Detaches from tmux session if inside one)*
* **■ Stop all & quit** *(Gracefully stops all running containers, unmounts, and exits)*