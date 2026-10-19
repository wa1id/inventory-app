# Build configuration

| File | Committed | Purpose |
|---|---|---|
| `Shared.xcconfig` | yes | Endpoints and timeouts shared by every configuration |
| `Debug.xcconfig`, `Preview.xcconfig`, `Release.xcconfig` | yes | Per-configuration environment name (`development`, `preview`, `production`) |
| `Secrets.xcconfig` | **no** | `INV_RECOGNITION_KEY` and `INV_SYNC_KEY`, the shared app keys sent as `x-inventory-key` |
| `Local.xcconfig` | **no** | Debug-only developer overrides, e.g. a LAN recognition server |

Write `Secrets.xcconfig` from the EAS production environment:

```sh
eas env:get production --variable-name EXPO_PUBLIC_RECOGNITION_KEY   # copy the value into INV_RECOGNITION_KEY
eas env:get production --variable-name EXPO_PUBLIC_SYNC_KEY          # copy the value into INV_SYNC_KEY
```

```
INV_RECOGNITION_KEY = <value>
INV_SYNC_KEY = <value>
```

Without it the app still builds; recognition and sync requests go out without the key, and the servers answer 401.
