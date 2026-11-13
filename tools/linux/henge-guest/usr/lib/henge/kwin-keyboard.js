// A KWin script that henge-keyboard loads when it is KWin's input method.
// KWin puts the input panel at the bottom of the area for maximized windows, above Plasma's panel, so
// henge-keyboard must know how much room panels take at the top and bottom of the screen.
// A script has no way to answer, so it calls a method that nothing has: henge-keyboard hears the call
// with "busctl monitor". The call goes to the bus's own name: Qt keeps a call to KWin's name inside KWin.
// It looks once a second and calls only when the room changes.
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

var timer = new QTimer();
timer.interval = 1000;
timer.timeout.connect(report);
timer.start();
report();
