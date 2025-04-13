# Changelog

## v1.0.1 (2025-04-14)
- fix(errors): Ensure logged enums are wrapped in `@tagName()` for readability.

## v1.0.0 (2025-04-06)
- New Keybinds:
    - Added ability to copy files.
      This is done by (y)anking the file, then (p)asting in the desired directory.
      This action can be (u)ndone and behind the scenes is a deletion.
      Currently this feature only supports files, folders, and symlinks.
    - Added force delete keybind. It's unbound by default.
    - Added keybind `v` to view additional information about the selected entry.
- A huge audit of `try` usages was conducted. As a result of this, Jido is much
  more resiliant to errors and should crash less often in known cases.
- Added `:h` command to view help / keybind menu.
- Added config option `true_dir_size` to see the true size of directories.
- Added [-v | --version] and [-h | --help] args.
- File permissions are now displayed in the file information bar to the bottom
  of Jido.
- Keybinds can now be unbound. Some keybinds are now unbound by default.
  See [Configuration](https://github.com/BrookJeynes/jido?tab=readme-ov-file#configuration)
  for more information.
- Fixes:
    - fix: Scrolling command history now provides the correct values.
    - fix: Ensure complete Git branch is displayed. Previously if the branch
      contained slashes, it would only retrieve the ending split.
    - fix: Allow the cursor to be moved left and right on text input.
    - fix: The keybind " " (spacebar) is now accepted by the config.
    - fix: Multi-char keybinds now throw errors instead of crashing.
    - fix: Undoing a delete/rename wont overwrite an item with the same name now.

## v0.9.9 (2025-04-06)
- feat: Added ability to copy folders.
- fix: Scrolling command history now provides the correct values.

## v0.9.8 (2025-04-04)
- fix: Ensure complete Git branch is displayed.
- refactor: Audit try usage to improve system resiliance.
- refactor: Removed need for enum based notifications.

## v0.9.7 (2025-04-01)
- feat: Added ability to copy files.
  This is done by (y)anking the file, then (p)asting in the desired directory.
  This action can be (u)ndone and behind the scenes is a deletion.
- fix: Allow the cursor to be moved left and right.
- refactor: Changed action struct field names to be more clear.
- refactor: Better ergonomics around writing to the log file.

## v0.9.6 (2025-03-31)
- feat: Added ability to unbound keybinds.
- feat: Added force delete keybind. It's unbound by default.

## v0.9.5 (2025-03-29)
- feat: Added [-v | --version] and [-h | --help] args.

## v0.9.4 (2025-03-29)
- feat: Added keybind `h` to view help / keybind menu.
- refactor: `List` drawing logic is now handled by the `Drawer{}`.

## v0.9.3 (2025-03-27)
- feat: The keybind " " is now accepted. This allows spacebar to be bound.
- feat: Duplicate keybind notification now includes additional information.
- fix: Multi-char keybinds now throw errors instead of crashing.
- fix: Remove need to init notification handler. This fixes many issues with 
  the places in the code notifications could be produced.

## v0.9.2 (2025-03-25)
- feat: Added keybind `v` to view additional information about the selected entry.
- feat: Added config option `true_dir_size` to see the true size of directories.
- fix: Undoing a delete/rename wont overwrite an item with the same name now.

## v0.9.1 (2025-03-23)
- feat: File permissions are now displayed in the file information bar to the 
  bottom of Jido.

## v0.9.0 (2025-03-21)
- New Keybinds:
    - Added keybind `<CTRL-r>` to reload config while Jido is running.
    - Added keybind `.` to hide/show hidden files at runtime.
      Default behaviour is still read from the config file if set.
- Added keybind rebinding.
  Jido now allows you to rebind certain keys. These can be rebound via the config
  file. See [Configuration](https://github.com/BrookJeynes/jido?tab=readme-ov-file#configuration) 
  for more information.
- Added file logger.
  This file logger allows Jido to provide users with more detailed log messages
  the notification system cannot. The log file can be found within the config
  directory under the file `log.txt`.
- Jido is now built with the latest stable version of Zig, v0.14.0.
- Fixes:
    - Hiding/showing hidden files after cd would cause all the files to visually
      disappear.
    - Off by one error when traversing command history causing the list to skip 
      some entries.
    - Empty commands are no longer added to the command history. This now means
      commands are whitespace trimmed.
    - Move logic to hide dot files from renderer to directory reader.
      This moves the logic to hide dot files out from the renderer to the
      directory reader. This means if hidden files are turned off, they aren't
      even stored.
    - Default styling didn't specify styling for notification box text. This
      would cause visual issues for light mode users.

## v0.8.3 (2025-03-19)
- feat: Added keybind `<CTRL-r>` to reload config while Jido is running.
- fix: Hiding/showing hidden files after cd would display no files.
- fix: Off by one error when traversing command history...
- fix: Dont add empty commands to command history.
- docs: Updated readme to mention new keybind.
- docs: Reordered keybinds section to add "Global" section.

## v0.8.2 (2025-03-18)
- fix: Move logic to hide dot files from renderer to directory reader.
  this moves the logic to hide dot files out from the renderer to the
  directory reader. This means if hidden files are turned off, they aren't
  even stored.
- feat: Added keybind `.` to hide/show hidden files at runtime.
  Default behaviour is still read from the config file if set.

## v0.8.1 (2025-03-11)
- feat: Jido is now built with zig 0.14.0.
- chore: Update packages.

## v0.8.0 (2025-01-07)
- Rebrand from zfe to Jido by @BrookJeynes in #16
  I felt that I wanted this project to have more of its own identity so I 
  decided now that this project is getting closer to a v1.0 release, it's time 
  to give it a proper name.
- Added command mode by @BrookJeynes in #14
  Command mode is a way for users to enter Jido commands. 
  Currently supported commands:
  ```
  Command mode:
  :q                 :Exit.
  :config            :Navigate to config directory if it exists.
  :trash             :Navigate to trash directory if it exists.
  :empty_trash       :Empty trash if it exists. This action cannot be undone.
  ```
- Deletes are now sent to `<config>/trash` instead of `/tmp`. by @BrookJeynes in #15
  Previously, deletes were sent to `/tmp`. This made it convenient for cleanup 
  however caused issues on certain distros. This was because the `/tmp` dir was 
  on a separate mount point and therefore the file was unable to be moved there. 
  Tying into this, there is now a new `empty_trash_on_exit` config option set to 
  false by default.
- Reworked the notification stylings. Notification stylings are now under the 
  notification namespace within the config file.
- The code used to detect the git branch no longer needs git installed on the 
  system.
- Displayed file size now shows the correct file size for files.

## v0.7.0 (2025-01-01)
- Fix notification segfaults by @BrookJeynes in #9
- Conform codebase styling by @BrookJeynes in #10
- Create release action by @BrookJeynes in #11
- Separate event and draw logic by @BrookJeynes in #12
- Updated config location from `$HOME/.config/zfe` to `$HOME/.zfe` by @BrookJeynes in 3cb9bb2
    - This means that the config can be found at either `$HOME/.zfe/` or 
      `$XDG_CONFIG_HOME/zfe/config/`. The old path will continue to work for 
      the meantime but has been deprecated.
- Show git branch when available by @BrookJeynes in #13

## v0.6.1 (2024-12-03)
- Updated libvaxis and refactored build.zig by @BrookJeynes in #7
- Notifications are now their own windows that appear to the right by @BrookJeynes in #8
    - Notifications are now their own windows that appear to the right of the 
      screen. they disappear after 3 seconds but note that renders only occur 
      after an action has been polled. this means that if you wait for 3 seconds 
      without an action, the notification wont disappear until an action occurs.
    - Added info notifications on actions such as renaming, deleting, changing 
      dir, etc.
    - Added notification_box colour setting to config.

## v0.5.0 (2024-06-05)
- Updated libvaxis dependency.
- Fixed an issue where viewing a PDF would freeze zfe. This fixes issue #5
- Added additional "Optional Dependencies" section to README to specify optional 
  dependencies for zfe (such as pdftotext for PDF viewing).
- Updated the way images are streamed in. This should help with #4 but I don't 
  think it ultimately fixes the issue at hand.

## v0.4.0 (2024-06-05)
- Fixed bug where cursor would jump back to the top after deleting, renaming, 
  creating, or undoing.
- Added new keybind `c` to change directory via path.
- Previous positions are saved when entering a new directory.
- PDFs can now be read if `pdftotext` is installed.
- Undo history can now only store the last 100 events.
- List scrolling is now squeaky smooth.
- Other general refactors and bug fixes.

## v0.3.0 (2024-05-30)
- Moved render and event handling logic to their own functions. This will make 
  it a more pleasant experience for contributors.
- Added issue templates for easier and more concise bug reports and feature 
  requests.
- Fixed issue where images would stop rendering if an event was emitted without 
  changing selected item.
- Implemented ability to delete files and folders.
- Implemented ability to rename files and folders.
- Implemented ability to undo deletions and renames within a session.
- Implemented ability to create folders and directories.
- Updated README with new keybinds.
- Added config option for styling info bar.

## v0.2.0 (2024-05-26)
- Implemented fuzzy search for items in a directory.
- Files can now be opened with `$EDITOR`.
- Error messages now displayed in app.
- Better errors when failing to read config.
- Stopped supporting Windows.

## v0.1.1 (2024-05-25)
- Added better error handling.
- Added new config style for error bar.
- Updated README to include config schema.
- Added MIT license.

## v0.1.0 (2024-05-24)
