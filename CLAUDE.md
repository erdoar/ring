# Ring: working notes for Claude

## Naming
- The application and the folder it is built into are both named `Ring <version>`, for example `Ring 0.5.2/Ring 0.5.2.app`. The version comes from `CFBundleShortVersionString` in `SI01/Support/Info.plist`; raise it there and nowhere else.
- `SI01/scripts/bundle-macos.sh` writes `SI01/build/Ring <version>/Ring <version>.app`. Any new script that creates an app, folder or disk image follows the same name.
