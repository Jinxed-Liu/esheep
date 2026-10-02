import Foundation

@main
struct InsightWorkflowRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func main() throws {
        let valid = #"{"title":"称重分析方案","analysis":"按真实相邻称重数据计算","steps":["查询同牧场称重","计算逐羊日增重"],"completionCriteria":["报告全部圈舍和样本缺口"],"missingInformation":[]}"#
        let plan = try {
            guard let value = InsightPlan.decode(valid) else { throw Failure(description: "Valid plan rejected.") }
            return value
        }()
        try require(plan.status == .ready && plan.version == 1 && plan.steps.count == 2,
                    "Valid plan did not become a versioned ready proposal.")
        try require(InsightPlan.decode("```json\n" + valid + "\n```") != nil, "Complete fenced JSON plan rejected.")
        for invalid in ["{}", valid.replacingOccurrences(of: "\"completionCriteria\":[\"报告全部圈舍和样本缺口\"]", with: "\"completionCriteria\":[]"),
                        valid.replacingOccurrences(of: "查询同牧场称重", with: "   "), "prefix " + valid] {
            try require(InsightPlan.decode(invalid) == nil, "Incomplete or ambiguous plan was accepted.")
        }
        let needsInfo = InsightPlan.decode(valid.replacingOccurrences(of: "\"missingInformation\":[]", with: "\"missingInformation\":[\"分析结束日期\"]"))
        try require(needsInfo?.status == .needsInformation, "Missing fields were marked ready to execute.")
        print("PASS: strict plan decoding, versions, complete JSON and missing-information state")

        var goal = InsightGoal(title: plan.title, steps: plan.steps,
            completionCriteria: plan.completionCriteria, planID: plan.id,
            planVersion: plan.version, rootMessageID: UUID())
        let firstMessage = UUID(), secondMessage = UUID()
        goal.status = .awaitingConfirmation
        goal.pendingDraftIDs = [UUID()]
        try require(goal.currentStep == 0 && goal.completedMessageIDs.isEmpty,
                    "Producing a confirmation card advanced the goal.")
        goal.activeStepMessageID = firstMessage
        goal.recordVerifiedStep(messageID: firstMessage)
        try require(goal.currentStep == 1 && goal.pendingDraftIDs.isEmpty && goal.status == .queued,
                    "Verified first step did not advance exactly once.")
        goal.recordVerifiedStep(messageID: firstMessage)
        try require(goal.currentStep == 1, "Replayed step advanced the goal twice.")
        goal.activeStepMessageID = secondMessage
        goal.recordVerifiedStep(messageID: secondMessage)
        try require(goal.currentStep == 2 && goal.status == .queued && !goal.status.isTerminal,
                    "Finishing planned steps skipped separate goal completion verification.")
        goal.status = .stopped
        goal.recordVerifiedStep(messageID: UUID())
        try require(goal.currentStep == 2 && goal.status == .stopped, "Late step resurrected a stopped goal.")
        print("PASS: confirmation never advances, verified step deduplication and separate final completion")

        let incompleteStep = InsightGoalStepEvaluation.decode(#"{"analysis":"尚缺数据","stepCompleted":false,"missingInformation":["圈舍"]}"#)
        try require(incompleteStep?.stepCompleted == false && incompleteStep?.missingInformation == ["圈舍"],
                    "An incomplete step was promoted to success.")
        try require(InsightGoalStepEvaluation.decode(#"{"analysis":"矛盾","stepCompleted":true,"missingInformation":["日期"]}"#) == nil,
                    "Step accepted completed=true with missing fields.")
        let incompleteGoal = InsightGoalCompletionEvaluation.decode(#"{"analysis":"仍需云端确认","completed":false,"remaining":["云回执"]}"#)
        try require(incompleteGoal?.completed == false && incompleteGoal?.remaining == ["云回执"],
                    "A goal with remaining conditions was promoted to completion.")
        try require(InsightGoalCompletionEvaluation.decode(#"{"analysis":"矛盾","completed":true,"remaining":["云回执"]}"#) == nil,
                    "Goal accepted completed=true with remaining conditions.")
        try require(InsightGoalCompletionEvaluation.decode(#"{"analysis":"已核验","completed":true,"remaining":[]}"#)?.completed == true,
                    "Fully checked completion cannot be decoded.")
        print("PASS: typed incomplete/complete evaluations and contradictory-success rejection")
        print("Workflow regression passed: 3 behavioral checks; no business writes or iOS build.")
    }
}
