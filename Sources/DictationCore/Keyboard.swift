/// Something that can enter text into whichever field has focus.
public protocol Keyboard: AnyObject {
    func type(_ text: String)
    func backspace(_ count: Int)
}
