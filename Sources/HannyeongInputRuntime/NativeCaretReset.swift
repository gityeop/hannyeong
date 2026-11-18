/// How the next IMK edit acquires a document range after composition ends.
public enum NativeCaretReset {
    case newContext
    case hostBackspace
}
