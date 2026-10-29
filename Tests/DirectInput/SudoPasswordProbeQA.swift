import Foundation
import Darwin

@main private struct SudoPasswordProbeQA {
    static func main() throws {
        typealias E = SudoPasswordProbe.Entry
        let shell = E(pid: 20, parent: 10, group: 20, tty: 1, foregroundGroup: 30, name: "zsh")
        let sudo = E(pid: 30, parent: 20, group: 30, tty: 1, foregroundGroup: 30, name: "sudo")
        func active(_ entries: [E], echo: Bool = false, root: pid_t = 10) throws -> Bool {
            try SudoPasswordProbe.active(rootPID: root, entries: entries) { _ in .init(echo: echo) }
        }
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "SudoPasswordProbeQA", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            print("PASS",label)
        }
        try check(try active([shell,sudo]), "foreground sudo with echo disabled is detected")
        try check(try !active([shell,sudo],echo:true), "sudo with echo restored is not password input")
        try check(try !active([shell]), "ordinary raw shell is not password input")
        try check(try !active([shell,sudo],root:99), "another application's sudo does not change this source")
        let background = E(pid:30,parent:20,group:30,tty:1,foregroundGroup:20,name:"sudo")
        try check(try !active([shell,background]), "background sudo does not change the source")
        let editor = E(pid: 40,parent:30,group:40,tty:2,foregroundGroup:40,name:"vim")
        try check(try !active([shell,sudo,editor]), "sudo running an editor is not authentication")
        let monitor = E(pid:40,parent:30,group:40,tty:2,foregroundGroup:40,name:"sudo")
        let nestedEditor = E(pid:50,parent:40,group:50,tty:2,foregroundGroup:50,name:"vim")
        try check(try !active([shell,sudo,monitor,nestedEditor]), "nested sudo monitor does not misclassify an editor")
        let detached = E(pid:30,parent:20,group:30,tty:-1,foregroundGroup:30,name:"sudo")
        try check(try !active([shell,detached]), "sudo without a controlling terminal is ignored")
        print("PASS sudo metadata classification; no process or TTY contents read")
    }
}
