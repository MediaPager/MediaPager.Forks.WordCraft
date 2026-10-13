from pathlib import Path
import sys

root = Path(sys.argv[1])

def patch(relative, before, after):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    if text.count(before) != 1:
        raise SystemExit(f"WordCraft patch anchor missing or ambiguous: {relative}")
    path.write_text(text.replace(before, after, 1), encoding="utf-8")

patch("crates/ui-egui/src/chrome.rs", "if app.ui.show_discord {", 'if app.ui.show_discord && !cfg!(target_arch = "wasm32") {')
patch("crates/ui-egui/src/backstage.rs",
      'for (label, id) in [("About", "about"), ("Discord community", "discord")] {',
      'for (label, id) in [("About", "about")].into_iter().chain((!cfg!(target_arch = "wasm32")).then_some(("Discord community", "discord"))) {')
patch("crates/ui-egui/src/options.rs",
      '    ui.checkbox(&mut app.ui.show_discord, tl!("Show the community button in the title bar"));',
      '    #[cfg(not(target_arch = "wasm32"))]\n    ui.checkbox(&mut app.ui.show_discord, tl!("Show the community button in the title bar"));')
patch("crates/ui-egui/src/ribbon.rs",
      '        big(ui, app, "discord", "Community\\nDiscord", "ui.discord", json!({}), false);',
      '        #[cfg(not(target_arch = "wasm32"))]\n        big(ui, app, "discord", "Community\\nDiscord", "ui.discord", json!({}), false);')
patch("crates/ui-egui/src/dialogs.rs",
      'ui.hyperlink_to(tl!("Join us on Discord: discord.gg/artcraft"), "https://discord.gg/artcraft");',
      '#[cfg(not(target_arch = "wasm32"))]\n                    ui.hyperlink_to(tl!("Join us on Discord: discord.gg/artcraft"), "https://discord.gg/artcraft");')
