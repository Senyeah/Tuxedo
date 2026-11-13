import Foundation

@main
struct KeyboardFollowTests {
    static func main() {
        // The guest asks: the keyboard comes up, then goes down.
        var f = KeyboardFollow(seq: 7)
        precondition(f.poll(wanted: true, seq: 7, typing: false, allowed: true) == nil) // an older machine's request
        precondition(f.poll(wanted: true, seq: 8, typing: false, allowed: true) == true)
        precondition(f.raised)
        precondition(f.poll(wanted: true, seq: 8, typing: true, allowed: true) == nil) // nothing new
        precondition(f.poll(wanted: false, seq: 9, typing: true, allowed: true) == false)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 9, typing: false, allowed: true) == nil)

        // The helper starts with "hide": nothing moves.
        f = KeyboardFollow(seq: 0)
        precondition(f.poll(wanted: false, seq: 1, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true) == nil)

        // A keyboard the person opened is not closed by the guest.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: true, allowed: true) == nil)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 2, typing: true, allowed: true) == nil)

        // The person closes a keyboard the guest raised: it stays down until the guest asks again.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f.closed()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: true) == nil)
        precondition(f.poll(wanted: true, seq: 3, typing: false, allowed: true) == true)
        // Closed, opened by hand, then the guest's hide: the keyboard stays.
        f.closed()
        precondition(f.poll(wanted: false, seq: 4, typing: true, allowed: true) == nil)

        // The same request sent again (the helper started again) with the keyboard closed by hand: it comes back.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f.closed()
        precondition(f.poll(wanted: true, seq: 2, typing: false, allowed: true) == true)

        // Not allowed (the console has the keys): nothing moves, and the newest request waits.
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)
        f = KeyboardFollow()
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: false) == nil)
        precondition(f.poll(wanted: false, seq: 2, typing: false, allowed: true) == nil)
        // Raised, then not allowed: a later hide does not close a keyboard that is not this one's.
        precondition(f.poll(wanted: true, seq: 3, typing: false, allowed: true) == true)
        precondition(f.poll(wanted: true, seq: 3, typing: true, allowed: false) == nil)
        precondition(!f.raised)
        precondition(f.poll(wanted: false, seq: 4, typing: true, allowed: true) == nil)

        // The count wraps or starts again: any change is news.
        f = KeyboardFollow(seq: 100)
        precondition(f.poll(wanted: true, seq: 1, typing: false, allowed: true) == true)

        print("test_keyboard_follow: ok")
    }
}
