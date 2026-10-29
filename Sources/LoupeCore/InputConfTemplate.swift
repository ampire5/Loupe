/// The text of `input.conf` with every built-in binding commented out, grouped as the cheat sheet is, with English notes
/// like `loupe.conf`'s (spec §2.4). Uncommented, its binding lines give exactly the built-in layout (a test checks);
/// `Loupe --print-input-conf` prints it.
public enum InputConfTemplate {
    public static let text = """
    # Loupe — key and mouse button bindings (mpv format: <input> <action> [args], comments start with #).
    # The file is reread together with loupe.conf whenever you switch to Loupe. The built-in layout
    # always applies: a line in this file adds a binding or replaces the built-in one for the same input.
    # Of two lines with the same input, the last one wins. "<input> ignore" removes a binding, built-in
    # or from a line above. Errors (unknown input or action, bad argument) show as a banner in the
    # window and go to stderr; a line with an error is skipped, the others still apply.
    # Below is the whole built-in layout, commented out: uncomment a line and change the action.
    #
    # Keys. Letters go by character (on a non-Latin layout such as Russian, the F key is still f); a capital
    # is Shift+letter (L ≡ Shift+l). Other keys go by position: LEFT RIGHT UP DOWN SPACE BS PGUP PGDWN HOME END
    # ESC ENTER KP_ENTER, 0…9, KP0…KP9 (numeric keypad), KP_ADD and KP_SUBTRACT (its + and −), = - [ ] / and
    # ? (≡ Shift+/). Modifiers: Shift+ and Alt+ (⌥). ⌘ and ⌃ belong to the menus and are not used in this file.
    #
    # Mouse buttons: MBTN_MID (wheel click), MBTN_BACK, MBTN_FORWARD; on the MX Master 4 also MX_PANEL
    # (haptic panel), MX_GESTURE (gesture button) and MX_SHIFT (button behind the wheel). How it is pressed:
    #   MX_PANEL fit                                   short: on release, with no wheel or movement
    #                                                  (if the button has no other bindings, right on press)
    #   MX_PANEL-long fill                             long: once mouse-long-press (loupe.conf) is reached;
    #                                                  on a button with "+ wheel" / "+ move", on release
    #   MX_PANEL+WHEEL add vibrance-amount 0.05        hold + wheel: every step, up adds
    #   MX_GESTURE+MX_THUMB add vibrance-amount 0.05   hold + thumb wheel: right adds
    #   MX_PANEL+MOVE add vibrance-amount 0.05         hold + move: a step per mouse-move-step pt, up adds
    #   MBTN_RIGHT+MBTN_MID fit-width                  middle while right is held
    # While a button has a "+ wheel" binding, the wheel goes only to it while the button is held.
    #
    # Actions: the ones further down in this file (previous, fit, toggle-auto-color…). Also:
    #   toggle-info-panel                              info panel (as ⌘I)
    #   add <key> <step>                               a step to a folder value: auto-color-strength or
    #                                                  vibrance-amount (0…1); a signed step of 0.01…1;
    #                                                  a wheel or move step down subtracts
    #   zoom-step                                      zoom at the pointer through the stops: a √2 step like
    #                                                  zoom-in, but it never skips a zoom-stops stop;
    #                                                  wheel or move up zooms in, down zooms out;
    #                                                  on a press or a key, one stop in
    #   next-folder, previous-folder                   on "+ wheel" / "+ move" they go both ways:
    #                                                  next-folder down goes to the next folder, up to
    #                                                  the previous one (previous-folder the reverse);
    #                                                  at most once per folder-scroll-repeat (loupe.conf)
    #   ignore                                         remove the binding

    # ── Navigation ────────────────────────────────────────────────────────────────────────────────────
    # LEFT previous                                 # previous photo
    # BS previous                                   # previous photo
    # PGUP previous                                 # previous photo
    # RIGHT next                                    # next photo
    # SPACE next                                    # next photo
    # PGDWN next                                    # next photo
    # Alt+LEFT previous-folder                      # previous folder
    # [ previous-folder                             # previous folder
    # Alt+RIGHT next-folder                         # next folder
    # ] next-folder                                 # next folder
    # HOME first                                    # first photo
    # END last                                      # last photo
    # ENTER browse                                  # folder browser on this photo's folder
    # KP_ENTER browse                               # the same, keypad Enter

    # ── Zoom ──────────────────────────────────────────────────────────────────────────────────────────
    # 0 fit                                         # fit to window
    # KP0 fit                                       # fit to window
    # 1 actual-100                                  # 100 %
    # KP1 actual-100                                # 100 %
    # 2 actual-200                                  # 200 %
    # KP2 actual-200                                # 200 %
    # 4 actual-400                                  # 400 %
    # 3 fill                                        # ordinary Fill, Manual zoom
    # KP3 fill                                      # ordinary Fill, Manual zoom
    # g toggle-zoom-set                             # Manual / SmartZoom (ordinary numeric presets stay fixed)
    # Alt+g cycle-subject-target                    # zoom to a face / a person / an object / where the eye goes
    # m cycle-detector-mode                         # next SmartZoom profile
    # Alt+s toggle-smart-zoom                       # Manual / SmartZoom; preserves view and profile
    # M save-detector-size                          # the size on screen as the mode's size (detector.conf)
    # n next-target                                 # the next target found on the photo
    # G toggle-subjects                             # show what Vision found: the subjects, the frame, its centre
    # Alt+Shift+g toggle-step-zoom                  # apply Auto (legacy mouse/key alias)
    # Alt+l remember-zoom                           # the tab's zoom choices for the folder (keys and menu choose for the tab)
    # KP4 actual-400                                # 400 %
    # w fit-width                                   # fit width
    # h fit-height                                  # fit height
    # x fill                                        # fill the window
    # z toggle-fit-actual                           # fit ↔ 100 % at the pointer
    # = zoom-in                                     # zoom in
    # KP_ADD zoom-in                                # zoom in
    # - zoom-out                                    # zoom out
    # KP_SUBTRACT zoom-out                          # zoom out
    # l toggle-keep-zoom                            # keep zoom and position in this folder, on/off
    # L save-keep-zoom                              # keep zoom as the default for all folders
    # k toggle-zoom-carry                           # a kept zoom keeps the share of the photo / the scale, this folder
    # K save-zoom-carry                             # share / scale as the default for all folders
    # Z zoom-subject                                # apply Auto using the selected SmartZoom profile (Shift+z)
    # Alt+k cycle-step-pan                          # after a step: the subject / the same place / the centre, this folder
    # Alt+K save-step-pan                           # after a step as the default for all folders
    # Alt+z cycle-zoom-anchor                       # gesture zoom towards the pointer / the centre / the subject
    # Alt+Z save-zoom-anchor                        # gesture zoom towards as the default for all folders
    # Shift+LEFT pan-left                           # pan left by a tenth of the window
    # Shift+RIGHT pan-right                         # pan right
    # Shift+UP pan-up                               # pan up
    # Shift+DOWN pan-down                           # pan down

    # ── Scaling ───────────────────────────────────────────────────────────────────────────────────────
    # s cycle-filter                                # next scaling filter in this folder
    # S save-filters                                # save filters as default
    # a toggle-antiring                             # anti-ringing in this folder, on/off
    # A save-antiring                               # save anti-ringing as default

    # ── Colour ────────────────────────────────────────────────────────────────────────────────────────
    # c toggle-auto-color                           # auto colour in this folder, on/off
    # C save-auto-color                             # save auto colour as default
    # v toggle-vibrance                             # vibrance in this folder, on/off
    # V save-vibrance                               # save vibrance as default

    # ── View ──────────────────────────────────────────────────────────────────────────────────────────
    # f toggle-full-screen                          # full screen
    # ESC exit-full-screen                          # leave full screen
    # i cycle-stats                                 # stats bar
    # t toggle-strip                                # pin / unpin the thumbnail strip
    # T toggle-strip-placement                      # strip beside or over the photo
    # ? cheat-sheet                                 # cheat sheet
    # p cycle-pan-indicators                        # pan indicators: auto / always / off
    # P save-pan-indicators                         # save pan indicators as default
    # d toggle-spread                               # two pages side by side in this folder, on/off
    # D save-spread                                 # two pages as the default for all folders
    # Alt+d shift-spread                            # shift the pairing by one page
    #   The info panel (toggle-info-panel) has no key by default: ⌘I in the menu and the mouse buttons below.

    # ── Window ────────────────────────────────────────────────────────────────────────────────────────
    #   By default no key or button touches tabs: ⌘T, ⌘N, ⌘W, ⇧⌘W, ⇧⌘T, ⌘[, ⇧⌘] and ⇧⌘[ are in the menus;
    #   ⌘1…⌘8 (tab by number), ⌘9 (last), ⌥⌘→ / ⌥⌘← (next / previous) work as in a browser.
    #   Bind them to a key or button like any other action:
    #   new-tab                                        new tab (as ⌘T)
    #   new-window                                     new window (as ⌘N)
    #   close-tab                                      close tab (as ⌘W)
    #   close-window                                   close window with all its tabs (as ⇧⌘W)
    #   reopen-tab                                     reopen the last closed tab (as ⇧⌘T)
    #   back                                           back to Recent, Folders or Stash, where it was opened from (as ⌘[)
    #   browse                                         folder browser on this photo's folder, photo selected (Return, double-click)
    #   next-tab, previous-tab                         next / previous tab of the window, wrapping around (as
    #                                                  ⌘⇧] / ⌘⇧[); on "+ wheel" / "+ move" they go both
    #                                                  ways, like next-folder; at most once per folder-scroll-repeat
    #   open-in-new-tab                                choose a file and open it in a new tab (as ⌥⌘O), whatever open-in says
    #   open-in-new-window                             choose a file and open it in a new window (as ⇧⌘O)
    #   home                                           Home in this tab (as ⇧⌘H)
    #   For example:
    #   MX_SHIFT+WHEEL next-tab                        button behind the wheel + wheel: down for the next tab, up for the previous
    #   MX_GESTURE+MX_THUMB next-tab                   gesture button + thumb wheel: tabs both ways
    #   MBTN_FORWARD-long new-tab                      forward, long: new tab
    #   MX_GESTURE-long close-tab                      gesture button, long: close tab

    # ── Trackpad ──────────────────────────────────────────────────────────────────────────────────────
    #   Trackpad gestures bind like a button: only an action, no -long or +WHEEL. The three-finger swipe
    #   up / down works unless System Settings › Trackpad gives it to Mission Control / Exposé.
    # TP_3UP browse                                 # three fingers up: folder browser on this photo's folder
    # TP_3DOWN back                                 # three fingers down: back to Recent, Folders or Stash
    # TP_3TAP cycle-stats                           # three-finger tap: stats bar
    # TP_FORCE toggle-info-panel                    # force click: info panel
    # TP_CLICK_DOWN next-tab                        # click held + two fingers down: next tab
    # TP_CLICK_UP previous-tab                      # click held + two fingers up: previous tab

    # ── Mouse ─────────────────────────────────────────────────────────────────────────────────────────
    # MX_PANEL toggle-auto-color                    # panel: auto colour in this folder, on/off
    # MX_PANEL-long toggle-vibrance                 # panel, long: vibrance in this folder, on/off
    # MX_PANEL+WHEEL add auto-color-strength 0.05   # panel + wheel: auto colour strength for this folder
    # MX_PANEL+MOVE add vibrance-amount 0.05        # panel + move up/down: vibrance strength for this folder
    # MBTN_MID toggle-fit-actual                    # middle: fit ↔ 100 % at the pointer
    # MBTN_MID-long fill                            # middle, long: fill the window
    # MBTN_BACK back                                # back: back to Recent, Folders or Stash, as in a browser
    # MBTN_BACK-long cycle-stats                    # back, long: stats bar
    # MBTN_BACK+WHEEL next-folder                   # back + wheel: down for the next folder, up for the previous
    # MBTN_FORWARD toggle-info-panel                # forward: info panel
    # MBTN_FORWARD+WHEEL zoom-step                  # forward + wheel: zoom through the stops at the pointer
    # MX_GESTURE cycle-stats                        # gesture button (in front of forward/back): stats bar
    # MX_GESTURE+WHEEL add vibrance-amount 0.05     # gesture button + wheel: vibrance strength for this folder
    # MBTN_RIGHT+MBTN_MID fit-width                 # right + middle: fit width
    #   Free: MBTN_FORWARD-long, MX_GESTURE-long, MX_SHIFT and every +MX_THUMB. Back (long) and the
    #   gesture button do the same thing, so one of them can be reassigned.
    #   Loupe hears the MX Master's back and forward buttons even alongside Mac Mouse Fix: mx-side-buttons in loupe.conf.

    """
}
