```markdown
# Minecraft Portable Launcher

A portable Minecraft launcher with server hosting capabilities.

## Features
- ✅ Portable (no installation required)
- ✅ Client launcher with hardware-based UUID
- ✅ Server hosting (Vanilla, Fabric, Forge, Paper, Purpur)
- ✅ Automatic server JAR downloads
- ✅ LAN world conversion tool
- ✅ Offline skin support
- ✅ Clean GUI with background image

## Requirements
- Windows 10/11
- PowerShell 5.1+
- Java 8/17/21/25 (in `runtime/` folder)

## Usage

### Client:
1. Run `MinecraftLauncher.exe`
2. Select version and mod loader
3. Enter username
4. Adjust memory allocation
5. Click "PLAY"

### Server:
1. Switch to "SERVER" tab
2. Select version and server type
3. Configure port, gamemode, difficulty
4. Allocate memory
5. Click "Start Server"

## Server Types
- **Vanilla** - Official Minecraft
- **Fabric** - Modern mods
- **Forge** - Classic mods
- **Paper** - High-performance plugins
- **Purpur** - Paper + extra features

## Folder Structure
MinecraftPortableLauncher/
├── runtime/              ← Java runtimes (8, 17, 21, 25)
├── versions/             ← Minecraft client versions
├── servers/              ← Server instances
├── config.json           ← Client configuration
└── server_config.json    ← Server configuration (auto-generated)

## Credits
Created by [Zachary Wilcox]
Minecraft is © Mojang Studios

## License
MIT License
```
