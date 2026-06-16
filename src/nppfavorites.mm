/*
 * NppFavorites — macOS port
 *
 * This plugin provides 6 favorite file slots that can be opened with
 * keyboard shortcuts (Ctrl+Option+1 through Ctrl+Option+6).
 * A "Manage Favorites" command opens the JSON config file for editing.
 *
 * On Windows, favorites are stored in an INI file via
 * GetPrivateProfileString. On macOS we use a JSON file in the host's
 * plugin config directory (~/.nextpad++/plugins/Config/NppFavorites.json).
 *
 * Menu items:
 *   - Favorite 0..5  (showing the file name or path)
 *   - (separator)
 *   - Manage Favorites  (Ctrl+Option+B)
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include <string>
#include <cstring>
#include <vector>

// ═══════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════

static const char *PLUGIN_NAME = "NppFavorites";
static const int NUM_FAVORITES = 6;
static const int NB_FUNC = NUM_FAVORITES + 2;  // 6 favorites + separator + Manage
static FuncItem funcItem[NUM_FAVORITES + 2];
NppData nppData;

static std::string favPaths[NUM_FAVORITES];
static std::string configFilePath;

// Shortcut keys for favorites: Ctrl+Option+1 through Ctrl+Option+6
static ShortcutKey favKeys[NUM_FAVORITES];
static ShortcutKey manageKey;

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

static NppHandle getCurScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static void showAlert(NSString *title, NSString *message) {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title;
        alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Config file management (JSON)
// ═══════════════════════════════════════════════════════════════════════════

static std::string getConfigPath() {
    @autoreleasepool {
        // Ask the host for its plugin config directory (creates it if needed).
        // Falls back to ~/Library/Application Support/Nextpad++/plugins/Config if
        // NPPM_GETPLUGINSCONFIGDIR returns empty (it does not on shipped versions).
        char buf[1024] = {};
        nppData._sendMessage(nppData._nppHandle,
                             NPPM_GETPLUGINSCONFIGDIR,
                             (uintptr_t)sizeof(buf),
                             (intptr_t)buf);
        NSString *dir;
        if (buf[0] != '\0') {
            dir = [NSString stringWithUTF8String:buf];
        } else {
            dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                       NSUserDomainMask, YES).firstObject
                       stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
        NSString *newPath = [dir stringByAppendingPathComponent:@"NppFavorites.json"];

        // One-shot migration from the pre-fix location
        // (~/.nextpad++/NppFavorites.json → plugins/Config/NppFavorites.json).
        NSString *oldPath = [NSHomeDirectory() stringByAppendingPathComponent:
                             @".nextpad++/NppFavorites.json"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![newPath isEqualToString:oldPath] &&
            [fm fileExistsAtPath:oldPath] &&
            ![fm fileExistsAtPath:newPath]) {
            [fm moveItemAtPath:oldPath toPath:newPath error:nil];
        }

        return std::string([newPath UTF8String]);
    }
}

static void loadConfig() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:configFilePath.c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            // Create default config with sample paths
            favPaths[0] = "/etc/hosts";
            favPaths[1] = "/etc/shells";
            for (int i = 2; i < NUM_FAVORITES; i++) {
                favPaths[i] = "";
            }
            // Save default config
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            for (int i = 0; i < NUM_FAVORITES; i++) {
                NSString *key = [NSString stringWithFormat:@"favFile%d", i];
                NSString *val = [NSString stringWithUTF8String:favPaths[i].c_str()];
                dict[key] = val;
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:dict
                                                          options:NSJSONWritingPrettyPrinted
                                                            error:nil];
            [json writeToFile:path atomically:YES];
            return;
        }

        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!dict) return;

        for (int i = 0; i < NUM_FAVORITES; i++) {
            NSString *key = [NSString stringWithFormat:@"favFile%d", i];
            NSString *val = dict[key];
            if (val && [val isKindOfClass:[NSString class]]) {
                favPaths[i] = std::string([val UTF8String]);
            } else {
                favPaths[i] = "";
            }
        }
    }
}

static void saveConfig() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:configFilePath.c_str()];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (int i = 0; i < NUM_FAVORITES; i++) {
            NSString *key = [NSString stringWithFormat:@"favFile%d", i];
            NSString *val = [NSString stringWithUTF8String:favPaths[i].c_str()];
            dict[key] = val;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
        [json writeToFile:path atomically:YES];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Open favorite file
// ═══════════════════════════════════════════════════════════════════════════

static void openFavFile(int index) {
    @autoreleasepool {
        // Reload config in case it was edited
        loadConfig();

        if (index < 0 || index >= NUM_FAVORITES) return;
        const std::string &path = favPaths[index];
        if (path.empty()) {
            NSString *msg = [NSString stringWithFormat:@"Favorite slot %d is empty.\n\n"
                             @"Use 'Manage Favorites' to configure your favorite files.", index + 1];
            showAlert(@"NppFavorites", msg);
            return;
        }

        // Check if file exists
        NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (![[NSFileManager defaultManager] fileExistsAtPath:nsPath]) {
            NSString *msg = [NSString stringWithFormat:@"File not found:\n%@", nsPath];
            showAlert(@"NppFavorites", msg);
            return;
        }

        nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)path.c_str());
    }
}

static void OpenFile0() { openFavFile(0); }
static void OpenFile1() { openFavFile(1); }
static void OpenFile2() { openFavFile(2); }
static void OpenFile3() { openFavFile(3); }
static void OpenFile4() { openFavFile(4); }
static void OpenFile5() { openFavFile(5); }

// Open the config file itself for editing
static void ManageFavorites() {
    @autoreleasepool {
        nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)configFilePath.c_str());
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Build menu item name for a favorite (truncate if too long)
// ═══════════════════════════════════════════════════════════════════════════

static void setMenuItemName(int index, const std::string &path) {
    char name[NPP_MENU_ITEM_SIZE];
    memset(name, 0, sizeof(name));

    if (path.empty()) {
        snprintf(name, NPP_MENU_ITEM_SIZE, "(empty slot %d)", index + 1);
    } else {
        // Show just the filename, or truncated path if too long
        const int MAX_DISPLAY = NPP_MENU_ITEM_SIZE - 1;
        if ((int)path.size() <= MAX_DISPLAY) {
            strncpy(name, path.c_str(), MAX_DISPLAY);
        } else {
            // Show first part ... last part
            int halfLen = (MAX_DISPLAY - 3) / 2;
            std::string display = path.substr(0, halfLen) + "..." + path.substr(path.size() - halfLen);
            strncpy(name, display.c_str(), MAX_DISPLAY);
        }
    }

    strncpy(funcItem[index]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin interface
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    configFilePath = getConfigPath();
    loadConfig();

    // Setup shortcut keys for favorites: Ctrl+Option+1..6
    static PFUNCPLUGINCMD openFuncs[NUM_FAVORITES] = {
        OpenFile0, OpenFile1, OpenFile2, OpenFile3, OpenFile4, OpenFile5
    };

    for (int i = 0; i < NUM_FAVORITES; i++) {
        favKeys[i]._isCtrl = true;
        favKeys[i]._isAlt = true;    // Option key
        favKeys[i]._isShift = false;
        favKeys[i]._isCmd = false;
        favKeys[i]._key = '1' + i;

        setMenuItemName(i, favPaths[i]);
        funcItem[i]._pFunc = openFuncs[i];
        funcItem[i]._init2Check = false;
        funcItem[i]._pShKey = &favKeys[i];
    }

    // Separator: host treats _pFunc == nullptr as NSMenuItem separatorItem
    int sepIdx = NUM_FAVORITES;
    funcItem[sepIdx]._itemName[0] = '\0';
    funcItem[sepIdx]._pFunc = nullptr;
    funcItem[sepIdx]._init2Check = false;
    funcItem[sepIdx]._pShKey = nullptr;

    // Manage Favorites: Ctrl+Option+B
    int manageIdx = NUM_FAVORITES + 1;
    manageKey._isCtrl = true;
    manageKey._isAlt = true;
    manageKey._isShift = false;
    manageKey._isCmd = false;
    manageKey._key = 'B';

    strncpy(funcItem[manageIdx]._itemName, "Manage Favorites", NPP_MENU_ITEM_SIZE);
    funcItem[manageIdx]._pFunc = ManageFavorites;
    funcItem[manageIdx]._init2Check = false;
    funcItem[manageIdx]._pShKey = &manageKey;
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    (void)n;
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
