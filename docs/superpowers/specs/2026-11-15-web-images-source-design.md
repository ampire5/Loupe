# Web Images source

Approved on 2026-11-15.

## Agreed scope

Web Images is a separate source in Loupe Home. It takes a text query, shows image results in a grid, and opens a selected result in Loupe’s viewer.

Previous and next follow the result order of the query that opened the viewer. Loupe fetches full-size images on demand and keeps downloaded images in a temporary cache. A permanent copy requires an explicit Save action.

Web Images exposes a multi-select engine filter in Loupe. The filter lists the image engines the configured server advertises, including engines that the server leaves disabled by default. The initial **Server defaults** selection searches the engines enabled on the server. Loupe remembers an explicit selection across relaunches. SearXNG remains responsible for installing and configuring engines.

Loupe settings include a SearXNG server URL, suggest `http://127.0.0.1:8888`, and provide a **Test Connection** action. The Home source appears once an address is configured. The same field accepts the address of another SearXNG instance.

Returning from the viewer restores the result grid, query and scroll position in the current session. After relaunch the search field contains the last query. Pressing Return submits it.

The Save action writes the original to a destination folder configured in Loupe. Saving uses that destination without a per-file dialog.

Near the end of the loaded results, the grid and viewer can request the next page. Append newly discovered results in server order and keep existing results in place. If loading an original fails, keep the preview when available, show a readable error, and offer to open the source page in the browser. Save is available once the original is available.

## Approaches

A native Home source uses SearXNG for search and Loupe’s viewer for image navigation and saving. It requires a client that understands image results and a loading path for remote images. This is the chosen approach.

An embedded SearXNG page would reuse its existing search and preferences UI. It would require additional bridging to put the result sequence, navigation and saving under Loupe’s control.

## Existing integration points

`LoupeHomeSource` registers custom pages through `HomeSourceInfo.page`. The Everything source uses this path and illustrates how to expose a source when its connection is configured. Web Images can use the same Home integration point.

The [SearXNG Search API](https://docs.searxng.org/dev/search_api.html) accepts an image search query and returns JSON when the server enables that format.

The viewer’s regular file opener requires a file URL. Its Photos path already accepts a source-ordered playlist. Reuse the ordering behavior and give Web Images its own loading path, so a downloaded image can open without scanning the cache directory or waiting for the rest of the query.

SearXNG owns its engine configuration. A compatible image result carries an image URL distinct from the source page URL. Generic JSON and XPath engines can add web results with thumbnails. An adapter for a new image provider should return structured image results with the original image URL.

## Search request behavior

Discover image engines from `GET /config` by checking each engine's `categories`. The `enabled` field reflects the server default for that engine. An unfiltered search sends `categories=images`. A filtered search sends an explicit, comma-separated `engines` list and omits `categories`, because this SearXNG version adds engines from both parameters when both are supplied. A search returns structured JSON and uses `pageno` for subsequent pages.

Keep the original image URL, thumbnail URL, source page URL, and engine attribution distinct. Use the result’s original image URL to recognize repeats across pages. If a later page returns the same image, keep its existing position.

## Defaults and failure behavior

- Choose the Save folder in settings. If it is missing or inaccessible, keep the image in the viewer and offer to open the folder setting.
- Preserve the original bytes and use a filename derived from the original when available. Add a numeric suffix on collision, preserving both files.
- Associate the remembered engine selection with the configured server. If the server no longer offers a saved engine, show that it is unavailable. If none of the selected engines remain, require a new selection or **Server defaults** before searching.
- When the search or engine selection changes, cancel requests for the previous result set. Keep a viewer’s sequence tied to the query and engine selection that opened it. Stop automatic pagination when the response adds no new images. Offer a retry on a page request failure.

## Acceptance scenarios

- After relaunch, the saved query and engine selection are visible. Search begins on Return.
- With two engines selected, the request uses only those engines. The next page appends new results without moving existing ones.
- Open an image at the end of a page and advance into the next page. Returning to the grid restores its position.
- When an original is unavailable, the preview and source-page action remain available. A loaded original saves to the configured folder. Saving twice creates distinct files.
