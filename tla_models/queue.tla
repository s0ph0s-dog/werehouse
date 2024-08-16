------------------------------- MODULE queue -------------------------------
VARIABLE state

States == {"Queued", "Error", "NeedsHelp", "Archived", "QueuedAgain"}
    
Init == state = "Queued"

Transition(from, to) ==
    /\ state = from
    /\ state' = to

SuccessfulArchive == Transition("Queued", "Archived")
FailedArchive == Transition("Queued", "Error")
SuccessfulArchiveRetry == Transition("QueuedAgain", "Archived")
FailedArchiveRetry == Transition("QueuedAgain", "Error")
HelpProvided == Transition("NeedsHelp", "QueuedAgain")

Next ==
    \/ FailedArchive
    \/ Transition("Queued", "Queued")
    \/ Transition("Queued", "NeedsHelp")
    \/ Transition("NeedsHelp", "NeedsHelp")
    \/ HelpProvided
    \/ FailedArchiveRetry
    \/ SuccessfulArchiveRetry
    \/ Transition("QueuedAgain", "NeedsHelp")
    \/ SuccessfulArchive
    
NamedTransitions ==
    /\ SuccessfulArchive
    /\ FailedArchive
    /\ SuccessfulArchiveRetry
    /\ FailedArchiveRetry
    /\ HelpProvided
    
Fairness == WF_state(Next) /\ SF_state(NamedTransitions) 

Spec ==
    /\ Init
    /\ [][Next]_state
    /\ Fairness

TypeInvariant ==
    /\ state \in States
    
Liveness ==
    <>[](state \in {"Error", "Archived"})

=============================================================================
\* Modification History
\* Last modified Thu Aug 15 14:07:13 EDT 2024 by s0ph0s
\* Created Fri Aug 09 18:50:09 EDT 2024 by s0ph0s
