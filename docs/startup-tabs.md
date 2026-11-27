# Startup Tabs

Use the **Startup Tabs** section in the new or existing environment editor to configure URLs that open automatically when an environment launches.

- Click **Add Startup Tab** to append an entry; its switch is turned on by default. If a newly added row loses focus while still empty, it is automatically discarded instead of leaving a blank entry behind.
- Turn off a row's switch to pause automatic opening while keeping its URL saved; turn it back on to resume.
- Drag the left row handle or use the row's context menu (**Move to First (Home)**, **Move Up**, **Move Down**) to reorder tabs, and use the hover remove button to the right of the switch to delete an entry.
- Click **Save** or **Create** to persist changes; **Revert** restores the latest saved configuration.
- Editing a running environment affects only future launches and does not close or append tabs in the open window.

On launch, all enabled entries open in order in the same browser window, with the first enabled tab selected and badged as **Home**. When no URLs are configured or every entry is paused, Safarier opens a single start page. A load failure in one tab does not affect the remaining tabs.

Valid `http` / `https` web URLs are accepted. The scheme can be omitted — for example, `example.com` normalizes to `https://example.com`. Paused entries must still hold a valid URL, and newly added blank rows must be filled in or removed before saving.

**Home** (`⇧⌘H`) uses the first enabled URL, or the start page when none is enabled. Pausing affects automatic startup only; manual navigation and **Reopen All Windows from Last Session** continue to work independently.

## CLI

Repeat `--url` in `profile create` or `profile update` to save enabled startup tabs in argument order:

```sh
safarier profile create --name Example \
  --url https://example.com/first \
  --url https://example.com/second

safarier profile update PROFILE_ID \
  --url https://example.com/second \
  --url https://example.com/first
```

When updating, passing `--url` replaces the entire list; omitting it preserves existing URLs, order, and paused states. Passing `--url none` clears the list. Schemeless host inputs (such as `example.com`) are normalized the same way as in the GUI. Per-tab pausing is managed in the GUI.

```sh
safarier profile update PROFILE_ID --url none
safarier launch PROFILE_ID --url https://example.com/once
```

`launch --url` overrides only the current launch without changing saved tabs. `probe` uses the first enabled URL unless overridden with `probe --url`.

## Configuration Compatibility

`startupTabs` is the single source of truth. Each item stores `id`, `url`, and `isEnabled`, and array order determines tab order.

When loading an older configuration without `startupTabs`, any legacy `startURL` is migrated into a single enabled entry. Once `startupTabs` is present (even as an empty array `[]`), Safarier never falls back to `startURL`. On save, the first enabled URL is projected into `startURL` for backward compatibility; when all entries are paused or the list is empty, `startURL` is omitted.

Older versions recognize only a single URL and cannot preserve the full list or paused states. Back up `profiles.json` in the metadata directory before downgrading.
