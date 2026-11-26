# Slot plugins

Add one `plugin=Name | HTTPS URL` line per page in `loupe.conf`, then reload the configuration.
Use the slot’s **+** menu to assign a plugin, or add its tab ID to an existing slot setting.
The configuration below assigns Photo Tools to the left slot.

```ini
plugin=Photo Tools | https://example.org/loupe-plugin.html
slot-left=plugin:photo-tools, overlay, glass, mouse-leaves, 400, hidden, at-once
```

Slot IDs use the plugin name in lowercase with hyphens between ASCII letters and numbers.
If two lines produce the same ID, Loupe uses the first line. A configured page may run JavaScript and
receive filesystem paths for its actions. Only configure pages you trust.

Assigned pages load while hidden. Use **File → Plugins** for the photo on screen, or the card context menu
in File View. Command-click toggles local cards and Shift-click selects a range. Right-click a selected
card to keep that selection. Use middle-click, Command-Return, or the card menu to open in a new tab.
Shift-double-click or the card menu opens in a new window.

## JavaScript API

The loaded main frame gets `window.loupe` with `version === 1`. Its background should be transparent
across both `html` and `body`, with light text suited to the slot's dark backdrop.

```js
window.addEventListener('loupeaction', async ({ detail }) => {
  try {
    await sendToMyService(detail.items);
    await loupe.complete(detail.id, { ok: true, message: 'Sent to Photo Tools' });
  } catch (error) {
    await loupe.complete(detail.id, { ok: false, message: error.message });
  }
});
await loupe.actions([
  { name: 'send', label: 'Send to Photo Tools', scope: 'viewer' },
  { name: 'add', label: 'Add to Photo Tools', scope: 'fileView' }
]);
```

- `loupe.actions(list)` replaces the current declarations. Names are unique on the page and use up to 32
  lowercase ASCII letters, digits, underscores or hyphens. Labels can be up to 60 characters. An empty list
  withdraws all actions. Reloading invalidates the previous page’s declarations.
- `loupeaction` carries `{ id, name, scope, items }`. Each item contains `{ path, name, kind }`. Paths are absolute
  Mac paths. Paths for archive members have the archive’s path followed by the member’s path, matching Loupe’s
  Copy Path command. Kinds are `file`, `folder`, `archive` and `place`. File View sends its selection in listing order.
- `loupe.complete(id, { ok, message })` reports the outcome in Loupe. Complete each invocation once.
- `loupe.openExternal(url)` opens a same-origin HTTPS URL in the default browser. It accepts a relative or an
  absolute URL. The browser uses its own session and cookies.

The three methods return promises that reject with an error message if the request is invalid.
