This basically needs to be able to be handed a serialized form of its
internal state, rehydrate that, run it through the pipeline, then serialize
its state back out (into a database).

The problem domain is web scraping.  Given a URL or list of URLs, this
system needs to scrape the primary image(s) from each of the URLs (along
with metadata, such as width, height, content type, author, tags, etc.),
determine if any of the images are duplicates of one that is already
archived, then archive the images.

This is divided into several stages:

1. Scrape

This stage queries all available scraper plugins to determine the first one
which reports that it is able to scrape each URL.  The first scraper plugin
that can scrape the URL is then told to scrape the URL.  This can succeed,
providing a list of image/video/animation files with metadata, or it can fail,
providing either a permanent error or a temporary error.

For video files, this stage also downloads thumbnails (if the source
provides them)

2. Decode

This stage decodes *images only* and updates their size, computes perceptual
hashes, and creates thumbnails.

3. Decide

This stage decides what to do with the scraped data. In some situations, the
decision is self-evident:
- If there is only one record, archive it.
- If there are multiple sources, and each of them have one record, choose
  the highest-resolution record.
In all other situations, this stage should indicate to the user that their
judgement is required. (More heuristics may be added in the future.)

4. Archive

This stage takes the selected entries from the previous stage and saves them
to disk, then inserts the metadata into the database.  If the user has
chosen to merge one or entries, this stage preserves whichever entry is
higher-resolution and additively merges the other metadata.

I've chosen to enforce that there are at most 3 attempts as a safety
invariant (avoid infinitely re-scraping something), and that the system
always ends in the Error or Archived status as a liveness property (require
it to either make progress or fail).  I don't think there are any other
things I need to require in order to confirm the system is working as
intended.

I don't love all the gotos, but I'm not sure there's a better way to model
the system.

-------------------------- MODULE ScraperPipeline --------------------------
EXTENDS Integers, Sequences, TLC

\* These should be model values.
CONSTANTS NO, YES, ANSWERED

ToDo == 0
Error == 1
NeedsHelp == 2
Archived == 3
ToDoAgain == 4

States == { ToDo, Error, NeedsHelp, Archived, ToDoAgain }

(*--algorithm ScraperPipeline
variables
    \* sources \in 0..4;
    status = ToDo;
    help_requested = NO;
    attempts = 0;
    
define
    TypeInvariant ==
        /\ status \in States
        /\ help_requested \in {NO, YES, ANSWERED}
        
    AtMostThreeAttempts ==
        attempts < 4
        
    \* Add this as an invariant.
    SafetyInvariants == AtMostThreeAttempts
end define;

fair process pipeline = "pipeline"
begin
    Deserialize:
        if attempts >= 3 then
            status := Error;
            goto Repeat;
        elsif help_requested /= NO then
            goto Decide;
        end if;
    Scrape:
        attempts := attempts + 1;
        either
            status := Error;
        or
            goto Deserialize;
        end either;
    Decode:
        either
            status := Error;
        or
            goto Deserialize;
        end either;
    Decide:
        if help_requested = NO then
            either
                help_requested := YES;
            or
                goto Deserialize;
            end either;
        elsif help_requested = YES then
            goto Deserialize;
        else
            goto Deserialize;
        end if;
    Archive:
        either
            status := Archived;
        or
            status := Error;
        end either;
    Repeat:
        if ~(status \in {Archived, Error}) then
            goto Deserialize;
        end if;
end process;

process user = "user"
begin
    AnswerHelp:
        either
        if help_requested = YES then
            help_requested := ANSWERED;
        end if;
        or skip end either;
end process;
end algorithm; *)
\* BEGIN TRANSLATION (chksum(pcal) = "a4289cc6" /\ chksum(tla) = "61350b8a")
VARIABLES status, help_requested, attempts, pc

(* define statement *)
TypeInvariant ==
    /\ status \in States
    /\ help_requested \in {NO, YES, ANSWERED}

AtMostThreeAttempts ==
    attempts < 4


SafetyInvariants == AtMostThreeAttempts


vars == << status, help_requested, attempts, pc >>

ProcSet == {"pipeline"} \cup {"user"}

Init == (* Global variables *)
        /\ status = ToDo
        /\ help_requested = NO
        /\ attempts = 0
        /\ pc = [self \in ProcSet |-> CASE self = "pipeline" -> "Deserialize"
                                        [] self = "user" -> "AnswerHelp"]

Deserialize == /\ pc["pipeline"] = "Deserialize"
               /\ IF attempts >= 3
                     THEN /\ status' = Error
                          /\ pc' = [pc EXCEPT !["pipeline"] = "Repeat"]
                     ELSE /\ IF help_requested /= NO
                                THEN /\ pc' = [pc EXCEPT !["pipeline"] = "Decide"]
                                ELSE /\ pc' = [pc EXCEPT !["pipeline"] = "Scrape"]
                          /\ UNCHANGED status
               /\ UNCHANGED << help_requested, attempts >>

Scrape == /\ pc["pipeline"] = "Scrape"
          /\ attempts' = attempts + 1
          /\ \/ /\ status' = Error
                /\ pc' = [pc EXCEPT !["pipeline"] = "Decode"]
             \/ /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                /\ UNCHANGED status
          /\ UNCHANGED help_requested

Decode == /\ pc["pipeline"] = "Decode"
          /\ \/ /\ status' = Error
                /\ pc' = [pc EXCEPT !["pipeline"] = "Decide"]
             \/ /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                /\ UNCHANGED status
          /\ UNCHANGED << help_requested, attempts >>

Decide == /\ pc["pipeline"] = "Decide"
          /\ IF help_requested = NO
                THEN /\ \/ /\ help_requested' = YES
                           /\ pc' = [pc EXCEPT !["pipeline"] = "Archive"]
                        \/ /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                           /\ UNCHANGED help_requested
                ELSE /\ IF help_requested = YES
                           THEN /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                           ELSE /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                     /\ UNCHANGED help_requested
          /\ UNCHANGED << status, attempts >>

Archive == /\ pc["pipeline"] = "Archive"
           /\ \/ /\ status' = Archived
              \/ /\ status' = Error
           /\ pc' = [pc EXCEPT !["pipeline"] = "Repeat"]
           /\ UNCHANGED << help_requested, attempts >>

Repeat == /\ pc["pipeline"] = "Repeat"
          /\ IF ~(status \in {Archived, Error})
                THEN /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                ELSE /\ pc' = [pc EXCEPT !["pipeline"] = "Done"]
          /\ UNCHANGED << status, help_requested, attempts >>

pipeline == Deserialize \/ Scrape \/ Decode \/ Decide \/ Archive \/ Repeat

AnswerHelp == /\ pc["user"] = "AnswerHelp"
              /\ \/ /\ IF help_requested = YES
                          THEN /\ help_requested' = ANSWERED
                          ELSE /\ TRUE
                               /\ UNCHANGED help_requested
                 \/ /\ TRUE
                    /\ UNCHANGED help_requested
              /\ pc' = [pc EXCEPT !["user"] = "Done"]
              /\ UNCHANGED << status, attempts >>

user == AnswerHelp

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == pipeline \/ user
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(pipeline)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION 

\* Add this as a temporal property.
Liveness == <>[](status \in {Error, Archived})

=============================================================================
\* Modification History
\* Last modified Fri Aug 16 21:51:31 EDT 2024 by s0ph0s
\* Created Fri Aug 09 20:40:37 EDT 2024 by s0ph0s
