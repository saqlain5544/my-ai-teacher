import Foundation

extension Features {
    /// The course board: the `lesson_plan` tool, and the hook that sends the board's state with each request, carries it
    /// into compaction summaries and keeps it in step with the tool's results.
    static let courseBoard = Module(id: "course-board",
                                    tools: [LessonPlanTool()],
                                    extensions: { _ in [CourseBoardExtension()] })
}
