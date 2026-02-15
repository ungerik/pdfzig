//! Embedded static assets for WebUI
//! Uses @embedFile to include HTML, CSS, and JS files in the binary

pub const index_html = @embedFile("assets/index.html");
pub const style_css = @embedFile("assets/style.css");
pub const app_js = @embedFile("assets/app.js");

// Favicons and icons
pub const favicon_ico = @embedFile("assets/favicon.ico");
pub const favicon_16x16_png = @embedFile("assets/favicon-16x16.png");
pub const favicon_32x32_png = @embedFile("assets/favicon-32x32.png");
pub const favicon_48x48_png = @embedFile("assets/favicon-48x48.png");
pub const apple_touch_icon_png = @embedFile("assets/apple-touch-icon.png");
pub const android_chrome_192x192_png = @embedFile("assets/android-chrome-192x192.png");
pub const android_chrome_512x512_png = @embedFile("assets/android-chrome-512x512.png");
pub const site_webmanifest = @embedFile("assets/site.webmanifest");
