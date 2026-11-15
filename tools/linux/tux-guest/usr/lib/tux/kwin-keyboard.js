// A KWin script that tux-keyboard loads when it is KWin's input method. It does two things.
//
// 1. KWin puts the input panel at the bottom of the area for maximized windows, above Plasma's panel, so
//    tux-keyboard must know how much room panels take at the top and bottom of the screen.
//    A script has no way to answer, so it calls a method that nothing has: tux-keyboard hears the call
//    with "busctl monitor". The call goes to the bus's own name: Qt keeps a call to KWin's name inside KWin.
//
// 2. KWin keeps only Wayland windows above the panel: it finds the window by its Wayland surface
//    (InputMethod::setTrackedWindow), and an X11 window (XWayland: many Electron programs) is not found.
//    This does for the active X11 window what Window::setVirtualKeyboardGeometry does for the others.
var last = "";
var ticks = 0;

// again: send the room even when it did not change. The helper takes what the bus gives it, so a false
// call from another program must not stay.
function report(again) {
    var output = workspace.activeScreen;
    var area = workspace.clientArea(KWin.MaximizeArea, output, workspace.currentDesktop);
    var all = output.geometry;
    var top = Math.round(area.y - all.y);
    var bottom = Math.round(all.y + all.height - area.y - area.height);
    var now = top + " " + bottom;
    if (now == last && !again) {
        return;
    }
    last = now;
    callDBus("org.freedesktop.DBus", "/Tux", "nz.jackgreenhill.tuxedo.Keyboard", "area", top, bottom);
}

var panel = null; // the input panel's window
var kept = {};    // by internalId: the place of each X11 window this moved, to give back

function isX11(w) {
    return ("" + w).indexOf("X11Window") >= 0; // the class name: scripts get no other sign
}

// The y of the keyboard's top edge, or -1 when it is down. The helper makes the panel's input region
// empty then, and KWin makes the panel's window empty from that.
function keyboardTop() {
    if (!panel || panel.deleted || panel.hidden || panel.frameGeometry.height <= 1) {
        return -1;
    }
    return panel.frameGeometry.y;
}

function isFull(w) {
    return w.maximizeMode == 3; // 1 is vertical only, 2 horizontal only
}

function same(g, k) {
    return g.x == k.x && g.y == k.y && g.width == k.width && g.height == k.height;
}

function place(w, k, x, y, width, height) {
    k.set = {x: x, y: y, width: width, height: height};
    var g = w.frameGeometry;
    if (same(g, k.set)) {
        return;
    }
    g.x = x;
    g.y = y;
    g.width = width;
    g.height = height;
    w.frameGeometry = g;
}

// The window is where this put it. If not, the person moved it or changed its maximized state:
// it is theirs then, and this forgets it.
function untouched(w, k) {
    return same(w.frameGeometry, k.set) && isFull(w) == k.maximized;
}

function giveBack(w) {
    var k = kept[w.internalId];
    if (!k) {
        return;
    }
    delete kept[w.internalId];
    if (!untouched(w, k)) {
        return;
    }
    var to = k.maximized ? workspace.clientArea(KWin.MaximizeArea, w) : k;
    place(w, {}, to.x, to.y, to.width, to.height);
}

// Only when the keyboard or the active window changes, as KWin does for Wayland windows. Not on a timer:
// a window that the person moves while the keyboard is up must stay.
function update() {
    var top = keyboardTop();
    var active = workspace.activeWindow;
    var windows = workspace.windowList();
    for (var i = 0; i < windows.length; i++) {
        if (kept[windows[i].internalId] && (top < 0 || windows[i] != active)) {
            giveBack(windows[i]);
        }
    }
    if (top < 0 || !active || !isX11(active) || active.fullScreen || active.desktopWindow || active.dock || !active.resizeable) {
        return;
    }
    var area = workspace.clientArea(KWin.MaximizeArea, active);
    var k = kept[active.internalId];
    if (k && !untouched(active, k)) {
        delete kept[active.internalId]; // start again from where the person left it
        k = null;
    }
    if (!k) {
        var g = active.frameGeometry;
        if (top >= g.y + g.height) {
            return; // the keyboard is not over it
        }
        k = kept[active.internalId] = {x: g.x, y: g.y, width: g.width, height: g.height, maximized: isFull(active)};
    }
    var base = k.maximized ? area : k;
    var height = Math.min(base.height, top - area.y);
    if (height <= 0) {
        return;
    }
    place(active, k, base.x, Math.max(top - height, area.y), base.width, height);
}

function findPanel() {
    if (panel && !panel.deleted) {
        return false;
    }
    panel = null;
    var windows = workspace.windowList();
    for (var i = 0; i < windows.length; i++) {
        if (windows[i].inputMethod) {
            panel = windows[i];
            panel.frameGeometryChanged.connect(update);
            panel.hiddenChanged.connect(update);
            return true;
        }
    }
    return false;
}

function look() {
    report(false);
    findPanel();
    update();
}

workspace.windowActivated.connect(look);
workspace.windowAdded.connect(look);
workspace.windowRemoved.connect(function (w) {
    delete kept[w.internalId];
    look();
});

// Once a second: a panel's room has no signal, and the input panel can come late. Every tenth time the room
// goes out again.
var timer = new QTimer();
timer.interval = 1000;
timer.timeout.connect(function () {
    ticks++;
    report(ticks % 10 == 0);
    if (findPanel()) {
        update();
    }
});
timer.start();
look();
