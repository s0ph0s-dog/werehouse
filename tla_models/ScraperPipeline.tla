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
    
define
    TypeInvariant ==
        /\ status \in States
        /\ help_requested \in {NO, YES, ANSWERED}
end define;

fair process pipeline = "pipeline"
begin
    Deserialize:
        if help_requested /= NO then
            goto Decide;
        end if;
    Scrape:
        either
            status := Error;
        or
            skip;
        end either;
    Decode:
        either
            status := Error;
        or
            skip;
        end either;
    Decide:
        if help_requested = NO then
            either
                help_requested := YES;
            or
                skip;
            end either;
        elsif help_requested = YES then
            goto Deserialize;
        else
            skip;
        end if;
    Archive:
        either
            status := Archived;
        or
            status := Error;
        end either;
    Repeat:
        goto Deserialize;
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
\* BEGIN TRANSLATION (chksum(pcal) = "b2ec6e39" /\ chksum(tla) = "4f82fa78")
VARIABLES status, help_requested, pc

(* define statement *)
TypeInvariant ==
    /\ status \in States
    /\ help_requested \in {NO, YES, ANSWERED}


vars == << status, help_requested, pc >>

ProcSet == {"pipeline"} \cup {"user"}

Init == (* Global variables *)
        /\ status = ToDo
        /\ help_requested = NO
        /\ pc = [self \in ProcSet |-> CASE self = "pipeline" -> "Deserialize"
                                        [] self = "user" -> "AnswerHelp"]

Deserialize == /\ pc["pipeline"] = "Deserialize"
               /\ IF help_requested /= NO
                     THEN /\ pc' = [pc EXCEPT !["pipeline"] = "Decide"]
                     ELSE /\ pc' = [pc EXCEPT !["pipeline"] = "Scrape"]
               /\ UNCHANGED << status, help_requested >>

Scrape == /\ pc["pipeline"] = "Scrape"
          /\ \/ /\ status' = Error
             \/ /\ TRUE
                /\ UNCHANGED status
          /\ pc' = [pc EXCEPT !["pipeline"] = "Decode"]
          /\ UNCHANGED help_requested

Decode == /\ pc["pipeline"] = "Decode"
          /\ \/ /\ status' = Error
             \/ /\ TRUE
                /\ UNCHANGED status
          /\ pc' = [pc EXCEPT !["pipeline"] = "Decide"]
          /\ UNCHANGED help_requested

Decide == /\ pc["pipeline"] = "Decide"
          /\ IF help_requested = NO
                THEN /\ \/ /\ help_requested' = YES
                        \/ /\ TRUE
                           /\ UNCHANGED help_requested
                     /\ pc' = [pc EXCEPT !["pipeline"] = "Archive"]
                ELSE /\ IF help_requested = YES
                           THEN /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
                           ELSE /\ TRUE
                                /\ pc' = [pc EXCEPT !["pipeline"] = "Archive"]
                     /\ UNCHANGED help_requested
          /\ UNCHANGED status

Archive == /\ pc["pipeline"] = "Archive"
           /\ \/ /\ status' = Archived
              \/ /\ status' = Error
           /\ pc' = [pc EXCEPT !["pipeline"] = "Repeat"]
           /\ UNCHANGED help_requested

Repeat == /\ pc["pipeline"] = "Repeat"
          /\ pc' = [pc EXCEPT !["pipeline"] = "Deserialize"]
          /\ UNCHANGED << status, help_requested >>

pipeline == Deserialize \/ Scrape \/ Decode \/ Decide \/ Archive \/ Repeat

AnswerHelp == /\ pc["user"] = "AnswerHelp"
              /\ \/ /\ IF help_requested = YES
                          THEN /\ help_requested' = ANSWERED
                          ELSE /\ TRUE
                               /\ UNCHANGED help_requested
                 \/ /\ TRUE
                    /\ UNCHANGED help_requested
              /\ pc' = [pc EXCEPT !["user"] = "Done"]
              /\ UNCHANGED status

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

=============================================================================
\* Modification History
\* Last modified Fri Aug 16 02:08:14 EDT 2024 by s0ph0s
\* Created Fri Aug 09 20:40:37 EDT 2024 by s0ph0s
