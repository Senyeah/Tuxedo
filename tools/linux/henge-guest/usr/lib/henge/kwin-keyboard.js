// A KWin script that henge-keyboard loads when it is KWin's input method. It does two things.
//
// 1. KWin puts the input panel at the bottom of the area for maximized windows, above Plasma's panel, so
//    henge-keyboard must know how much room panels take at the top and bottom of the screen.
//    A script has no way to answer, so it calls a method that nothing has: henge-keyboard hears the call
//    with "busctl monitor". The call goes to the bus's own name: Qt keeps a call to KWin's name inside KWin.
//
// 2. KWin keeps only Wayland windows above the panel: it finds the window by its Wayland surface
//    (InputMethod::setTrackedWindow), and an X11 window (XWayland: many Electron programs) is not found.
//    This does for the active X11 window what Window::setVirtualKeyboardGeometry does for the others.
var last = "";

function report() {
    var output = workspace.activeScreen;
    var area = workspace.clientArea(KWin.MaximizeArea, output, workspace.currentDesktop);
    var all = output.geometry;
    var top = Math.round(area.y - all.y);
    var bottom = Math.round(all.y + all.height - area.y - area.height);
    var now = top + " " + bottom;
    if (now == last) {
        return;
    }
    last = now;
    callDBus("org.freedesktop.DBus", "/Henge", "dev.henge.Keyboard", "area", top, bottom);
}

var panel = null; // the input panel's window
var kept = {};    // by internalId: the place of each X11 window this moved, to give back

function isX11(w) {
    return ("" + w).indexOf("X11Window") >= 0; // the class name: scripts get no other sign
}

// The y of the keyboard's top edge, or -1 when it is down.
function keyboardTop() {
    if (!panel || panel.deleted || panel.hidden || panel.frameGeometry.height <= 0) {
        return -1;
    }
    return panel.frameGeometry.y;
}

function place(w, x, y, width, height) {
    var g = w.frameGeometry;
    if (g.x == x && g.y == y && g.width == width && g.height == height) {
        return;
    }
    g.x = x;
    g.y = y;
    g.width = width;
    g.height = height;
    w.frameGeometry = g;
}

function giveBack(w) {
    var k = kept[w.internalId];
    if (!k) {
        return;
    }
    delete kept[w.internalId];
    var to = k.maximized ? workspace.clientArea(KWin.MaximizeArea, w) : k;
    place(w, to.x, to.y, to.width, to.height);
}

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
    if (!k) {
        var g = active.frameGeometry;
        if (top >= g.y + g.height) {
            return; // the keyboard is not over it
        }
        k = kept[active.internalId] = {x: g.x, y: g.y, width: g.width, height: g.height, maximized: (active.maximizeMode & 2) != 0};
    }
    var base = k.maximized ? area : k;
    var height = Math.min(base.height, top - area.y);
    if (height <= 0) {
        return;
    }
    place(active, base.x, Math.max(top - height, area.y), base.width, height);
}

function findPanel() {
    if (panel && !panel.deleted) {
        return;
    }
    panel = null;
    var windows = workspace.windowList();
    for (var i = 0; i < windows.length; i++) {
        if (windows[i].inputMethod) {
            panel = windows[i];
            panel.frameGeometryChanged.connect(update);
            panel.hiddenChanged.connect(update);
            return;
        }
    }
}

function look() {
    report();
    findPanel();
    update();
}

workspace.windowActivated.connect(look);
workspace.windowAdded.connect(look);
workspace.windowRemoved.connect(function (w) {
    delete kept[w.internalId];
    look();
});

// Once a second as well: a panel's room has no signal
var timer = new QTimer();
timer.interval = 1000;
timer.timeout.connect(look);
timer.start();
look();
