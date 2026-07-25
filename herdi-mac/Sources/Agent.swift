import Foundation

enum AgentStatus: String, Codable {
    case working, blocked, idle, unknown
}

@Observable
final class Agent: Identifiable {
    let id: String
    var name: String
    var status: AgentStatus
    var project: String
    var cwd: String
    var host: String
    var prompt: String?
    var options: [String]?
    /// Needed to jump to the agent: herdr focuses a workspace and a tab, and has no
    /// "focus pane by id" command. Optional because push-event deltas omit them.
    var workspaceId: String?
    var tabId: String?

    init(id: String, name: String, status: AgentStatus, project: String, cwd: String,
         host: String = "local", workspaceId: String? = nil, tabId: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.project = project
        self.cwd = cwd
        self.host = host
        self.workspaceId = workspaceId
        self.tabId = tabId
    }

    /// True when herdr can be driven to this agent — i.e. it is on this machine and we know where.
    var canJump: Bool { host == "local" && !(workspaceId ?? "").isEmpty && !(tabId ?? "").isEmpty }
}

struct AgentMessage: Codable {
    let type: String
    let agents: [AgentData]?
    let pane_id: String?
    let agent: String?
    let project: String?
    let prompt: String?
    let options: [String]?

    // Every field except pane_id is optional: the relay's poll loop sends the full record, but its
    // push-event path sends a reduced delta. A non-optional field missing from that delta would
    // fail decoding and silently drop the whole message.
    struct AgentData: Codable {
        let pane_id: String
        let agent: String?
        let status: String?
        let cwd: String?
        let project: String?
        let host: String?
        let workspace_id: String?
        let tab_id: String?
    }
}

struct ResponseMessage: Codable {
    let type = "respond"
    let pane_id: String
    let text: String
}
