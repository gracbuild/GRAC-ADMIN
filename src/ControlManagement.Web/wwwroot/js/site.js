// Please see documentation at https://learn.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

/* ============================================================================
   GRAC URL helpers — the single place that knows where this application lives.

   The app is published under an IIS virtual directory (for example
   /gracnewAdmin), so Request.PathBase is not empty and a bare "/Repository/..."
   would navigate straight out of the application. _Layout emits the value as
   window.cmPathBase; everything client-side resolves in-app URLs through here.

   window.cmPathBase is read on each call rather than captured at load time,
   because _Layout loads this file just before it assigns the variable.
   ==========================================================================*/
(function (global) {
    "use strict";

    function base() {
        return String(global.cmPathBase || "").replace(/\/+$/, "");
    }

    /* Resolve an application-relative path against the application root. */
    function app(path) {
        var suffix = String(path || "");
        if (suffix && suffix.charAt(0) !== "/") suffix = "/" + suffix;
        return base() + suffix;
    }

    /* True only when `url` is a page of THIS application: same origin AND
       underneath the application root.

       Testing the origin alone is not enough. Several GRAC applications are
       published side by side on one host, so a Referer from a sibling app
       passes an origin check and then quietly navigates the user out of this
       application — which is what made "save and go back" land on the wrong
       base URL. */
    function isInternal(url) {
        if (!url) return false;

        // Parse as an absolute URL first. Anything that is not absolute is
        // accepted for resolution only when it is a root-relative path, because
        // new URL(value, base) happily turns arbitrary text into an in-app URL
        // ("::junk::" would resolve to <base>/::junk:: and look internal).
        var parsed = null;
        try { parsed = new URL(String(url)); } catch (error) { parsed = null; }
        if (!parsed) {
            if (String(url).charAt(0) !== "/") return false;
            try { parsed = new URL(String(url), global.location.href); } catch (error) { return false; }
        }

        // Blocks javascript:, data: and friends before the origin test, so the
        // intent is stated rather than relied on as a side effect.
        if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
        if (parsed.origin !== global.location.origin) return false;

        var root = base().toLowerCase();
        if (!root) return true;
        var path = parsed.pathname.toLowerCase();
        return path === root || path.indexOf(root + "/") === 0;
    }

    /* Where a full-page form goes when it closes: back where the user came
       from when that is a page of this application, otherwise the screen the
       form belongs to. Never returns a URL outside the application root. */
    function safeReturn(candidate, fallbackPath) {
        return isInternal(candidate) ? candidate : app(fallbackPath);
    }

    global.gracUrl = { app: app, isInternal: isInternal, safeReturn: safeReturn };
})(window);
