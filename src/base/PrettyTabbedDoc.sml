(** Copyright (c) 2022 Sam Westrick
  *
  * See the file LICENSE for details.
  *)

(** Functor argument CustomString could either be a standard string, or could
  * be a TerminalColorString, etc.
  *)
functor PrettyTabbedDoc
  (CustomString:
    sig
      type t
      val substring: t * int * int -> t

      (* should be visually distinct, e.g., color the background.
       * the integer argument is a depth; this can be ignored (in which
       * case all depths will be emphasized the same) or can be used
       * to distinguish different tab depths
       *)
      val emphasize: int -> t -> t

      val fromString: string -> t
      val toString: t -> string
      val size: t -> int
      val concat: t list -> t
    end) :>
sig
  type doc
  type t = doc

  exception InvalidDoc

  val empty: doc
  val space: doc
  val newline: doc
  val text: CustomString.t -> doc
  val concat: doc * doc -> doc

  datatype style =
    Inplace
  | Indented of {minIndent: int} option
  | RigidInplace
  | RigidIndented of {minIndent: int} option

  type tab
  val root: tab
  val newTab: tab -> style * (tab -> doc) -> doc
  val at: tab -> doc -> doc
  val cond: tab -> {inactive: doc, active: doc} -> doc

  val pretty: {ribbonFrac: real, maxWidth: int, indentWidth: int, debug: bool}
           -> doc
           -> CustomString.t

  val toString: doc -> CustomString.t
end =
struct

  (* IDEA: lazily activate tabs. If size/ribbon are violated, then
   * promote the outermost tab.
   *
   * Promotion follows this progression, which improves horizontal compaction:
   *       Flattened -> ActivatedInPlace -> ActivatedIndented
   *           -----------------> (horizontal compaction)
   *)


  (* ====================================================================== *)


  datatype style =
    Inplace
  | Indented of {minIndent: int} option
  | RigidInplace
  | RigidIndented of {minIndent: int} option


  structure Tab =
  struct
    datatype activation_state = Flattened | Activated of int option
    (* datatype location_state = LocUnknown | LocInPlace | LocIndented  *)
    datatype state =
      Fresh
    | Usable of activation_state
    | Completed

    datatype tab =
      Tab of {state: state ref, id: int, style: style, parent: tab}
    | Root

    type t = tab

    val tabCounter = ref 0

    fun make parent style =
      let
        val c = !tabCounter
      in
        tabCounter := c+1;
        Tab
          { state = ref Fresh
          , id = c
          , style = style
          , parent = parent
          }
      end

    fun eq (t1, t2) =
      case (t1, t2) of
        (Tab {id=c1, ...}, Tab {id=c2, ...}) => c1 = c2
      | (Root, Root) => true
      | _ => false

    fun style t =
      case t of
        Root => Inplace
      | Tab {style=s, ...} => s

    fun isRigid t =
      case style t of
        RigidInplace => true
      | RigidIndented _ => true
      | _ => false

    fun isInplace t =
      case style t of
        RigidInplace => true
      | Inplace => true
      | _ => false

    fun minIndent t =
      case style t of
        Indented (SOME {minIndent=i}) => i
      | RigidIndented (SOME {minIndent=i}) => i
      | _ => 0

    fun getState t =
      case t of
        Tab {state=r, ...} => !r
      | Root => Usable (Activated (SOME 0))

    fun setState t x =
      case t of
        Tab {state=r, ...} => r := x
      | Root => ()

    fun isActivated t =
      case t of
        Root => true
      | Tab {state=r, ...} =>
          case !r of
            Usable (Activated _) => true
          | Usable (Flattened) => false
          | _ => raise Fail "PrettyTabbedDoc.Tab.isActivated: bad tab"

    fun parent t =
      case t of
        Root => NONE
      | Tab {parent=p, ...} => SOME p

    fun oldestInactiveParent t =
      if isActivated t then NONE else
      case parent t of
        SOME p =>
          if isActivated p then
            SOME t
          else
            oldestInactiveParent p
      | NONE => SOME t

    fun infoString t =
      case t of
        Root => "[root]"
      | Tab {state=r, id=c, parent=p, ...} =>
          let
            val pinfo =
              case p of
                Root => ""
              | Tab {id=pid, ...} => Int.toString pid ^ "<-"
            val info =
              case !r of
                Usable Flattened => "f"
              | Usable (Activated NONE) => "a?"
              | Usable (Activated (SOME _)) => "a"
              | _ => "x"
          in
            "[" ^ pinfo ^ Int.toString c ^ info ^ "]"
          end

    fun name t =
      case t of
        Root => "root"
      | Tab {id=c, ...} => Int.toString c


    fun compare (t1, t2) =
      case (t1, t2) of
        (Tab {id=c1, ...}, Tab {id=c2, ...}) => Int.compare (c1, c2)
      | (Root, Root) => EQUAL
      | (Root, _) => LESS
      | (_, Root) => GREATER

    fun depth t =
      case t of
        Root => 0
      | Tab {parent=p, ...} => 1 + depth p

  end

  structure TabDict = Dict(Tab)
  structure TabSet = Set(Tab)

  (* ====================================================================== *)

  exception InvalidDoc

  type tab = Tab.t

  val root = Tab.Root

  datatype doc =
    Empty
  | Space
  | Newline
  | Concat of doc * doc
  | Text of CustomString.t
  | At of tab * doc
  | NewTab of {parent: tab, tab: tab, doc: doc}
  | Cond of {tab: tab, inactive: doc, active: doc}

  type t = doc

  val empty = Empty
  val newline = Newline
  val space = Space
  val text = Text
  fun at t d = At (t, d)

  fun cond tab {inactive, active} =
    Cond {tab=tab, inactive=inactive, active=active}

  fun concat (d1, d2) =
    case (d1, d2) of
      (Empty, _) => d2
    | (_, Empty) => d1
    | _ => Concat (d1, d2)

  fun newTab parent (style, genDocUsingTab) =
    let
      val t = Tab.make parent style
      val d = genDocUsingTab t
    in
      NewTab {parent = parent, tab = t, doc = d}
    end

  (* ====================================================================== *)

  fun allTabsInDoc d =
    let
      fun loop acc d =
        case d of
          NewTab {tab, doc, ...} => loop (tab :: acc) doc
        | Concat (d1, d2) => loop (loop acc d1) d2
        | Cond {inactive, active, ...} => loop (loop acc inactive) active
        | At (_, doc) => loop acc doc
        | _ => acc
    in
      loop [] d
    end

  (* ====================================================================== *)


  fun spaces count =
    CustomString.fromString (CharVector.tabulate (count, fn _ => #" "))


  datatype sentry =
    StartTabHighlight of {tab: tab, col: int}
  | StartMaxWidthHighlight of {col: int}


  datatype eentry =
    EndTabHighlight of {tab: tab, col: int}
  | EndMaxWidthHighlight of {col: int}


  fun sentryCol se =
    case se of
      StartTabHighlight {col, ...} => col
    | StartMaxWidthHighlight {col} => col


  fun eentryCol ee =
    case ee of
      EndTabHighlight {col, ...} => col
    | EndMaxWidthHighlight {col} => col


  fun sentryCmp (se1, se2) =
    case (se1, se2) of
      (StartTabHighlight {tab=tab1, col=col1}, StartTabHighlight {tab=tab2, col=col2}) =>
        (case Int.compare (col1, col2) of
          EQUAL => Tab.compare (tab1, tab2)
        | other => other)

    | (StartTabHighlight {col=col1, ...}, StartMaxWidthHighlight {col=col2}) =>
        (case Int.compare (col1, col2) of
          EQUAL => LESS
        | other => other)

    | (StartMaxWidthHighlight {col=col1}, StartTabHighlight {col=col2, ...}) =>
        (case Int.compare (col1, col2) of
          EQUAL => GREATER
        | other => other)

    | _ => Int.compare (sentryCol se1, sentryCol se2)


  fun eentryCmp (ee1, ee2) =
    case (ee1, ee2) of
      (EndTabHighlight {tab=tab1, col=col1}, EndTabHighlight {tab=tab2, col=col2}) =>
        (case Int.compare (col1, col2) of
          EQUAL => Tab.compare (tab1, tab2)
        | other => other)

    | (EndTabHighlight {col=col1, ...}, EndMaxWidthHighlight {col=col2}) =>
        (case Int.compare (col1, col2) of
          EQUAL => LESS
        | other => other)

    | (EndMaxWidthHighlight {col=col1}, EndTabHighlight {col=col2, ...}) =>
        (case Int.compare (col1, col2) of
          EQUAL => GREATER
        | other => other)

    | _ => Int.compare (eentryCol ee1, eentryCol ee2)


  fun matchingStartEndEntries (se, ee) =
    case (se, ee) of
      (StartTabHighlight {tab=st, col=sc}, EndTabHighlight {tab=et, col=ec, ...}) =>
        Tab.eq (st, et) andalso sc = ec

    | (StartMaxWidthHighlight {col=sc}, EndMaxWidthHighlight {col=ec}) =>
        sc = ec

    | _ => false


  fun sentryEmphasizer se =
    case se of
      StartTabHighlight {tab, ...} => CustomString.emphasize (Tab.depth tab)
    | StartMaxWidthHighlight {...} => CustomString.emphasize 10000000


  fun sentrytos se =
    case se of
      StartTabHighlight {tab=st, col=scol} =>
        "StartTabHighlight {tab = " ^ Tab.name st ^ ", col = " ^ Int.toString scol ^ "}"

    | StartMaxWidthHighlight {col} =>
        "StartMaxWidthHighlight {col = " ^ Int.toString col ^ "}"


  fun eentrytos ee =
    case ee of
      EndTabHighlight {tab=et, col=ecol} =>
        "EndTabHighlight {tab = " ^ Tab.name et ^ ", col = " ^ Int.toString ecol ^ "}"

    | EndMaxWidthHighlight {col} =>
        "EndMaxWidthHighlight {col = " ^ Int.toString col ^ "}"


  fun sentryInfo se =
    case se of
      StartTabHighlight {tab, col} =>
        sentryEmphasizer se (CustomString.fromString ("^" ^ Tab.name tab))
    | StartMaxWidthHighlight _ =>
        sentryEmphasizer se (CustomString.fromString "^maxWidth")

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)

  structure Item =
  struct

    datatype item =
      Spaces of int
    | Newline
    | Stuff of CustomString.t
    | StartDebug of sentry
    | EndDebug of eentry

    type t = item


    fun width item =
      case item of
        Spaces n => n
      | Stuff s => CustomString.size s
      | _ => raise Fail "PrettyTabbedDoc.Item.width"


    fun toString item =
      case item of
        Spaces n => "Spaces(" ^ Int.toString n ^ ")"
      | Stuff s =>
          if width item <= 5 then
            "Stuff('" ^ CustomString.toString s ^ "')"
          else
            "Stuff('" ^ String.substring (CustomString.toString s, 0, 5) ^ "...')"
      | _ => "???"


    fun split item i =
      if i < 0 orelse i+1 > width item then
        raise Fail "PrettyTabbedDoc.Item.split: size"
      else
      (* i+1 <= width item *)
      case item of
        Spaces n =>
          (Spaces i, CustomString.fromString " ", Spaces (n-i-1))
      | Stuff s =>
          let
            val n = CustomString.size s
            val left = CustomString.substring (s, 0, i)
            val mid = CustomString.substring (s, i, 1)
            val right = CustomString.substring (s, i+1, n-i-1)
          in
            (Stuff left, mid, Stuff right)
          end
      | _ => raise Fail "PrettyTabbedDoc.Item.split: bad item"

  end

  type item = Item.t

  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)


  fun implementDebugs maxWidth items =
    let
      fun highlightActive accCurrLine acc startDebugs =
        let
          val orderedHighlightCols =
            Mergesort.sort sentryCmp (Seq.fromList startDebugs)

          fun processItem (item, (currCol, hi, acc)) =
            let
              val () = ()
              (* val _ = print ("processItem " ^ itos item ^ "\n") *)
              val nextHighlightCol =
                if hi < Seq.length orderedHighlightCols then
                  sentryCol (Seq.nth orderedHighlightCols hi)
                else
                  valOf Int.maxInt

              val n = Item.width item
            in
              if nextHighlightCol < currCol then
                processItem (item, (currCol, hi+1, acc))
              else if currCol+n <= nextHighlightCol then
                (currCol+n, hi, item :: acc)
              else
                let
                  val emphasizer = sentryEmphasizer (Seq.nth orderedHighlightCols hi)
                  val (left, mid, right) = Item.split item (nextHighlightCol-currCol)
                  (*
                  val _ =
                    print ("item: " ^ itos item
                       ^ " split into (" ^ itos left ^ ", _, " ^ itos right ^ ")"
                       ^ " nextHightlightCol: " ^ Int.toString nextHighlightCol
                       ^ " currCol: " ^ Int.toString currCol
                       ^ " itemWidth: " ^ Int.toString n
                       ^ " hi: " ^ Int.toString hi
                       ^ "\n")
                  *)
                in
                  processItem (right,
                   ( nextHighlightCol + 1
                   , hi+1
                   , Item.Stuff (emphasizer mid)
                     :: left :: acc
                   ))
                end
            end

          val (currCol, hi, acc) = List.foldr processItem (0, 0, acc) accCurrLine

          (* finish out the columns to highlight, if any remaining *)
          val (_, acc) =
            Util.loop (hi, Seq.length orderedHighlightCols) (currCol, acc)
            (fn ((currCol, acc), hi) =>
              let
                val sentry = Seq.nth orderedHighlightCols hi
                val nextHighlightCol = sentryCol sentry
                val emphasizer = sentryEmphasizer sentry
              in
                if currCol > nextHighlightCol then
                  (currCol, acc)
                else
                  (* currCol <= nextHighlightCol *)
                  ( nextHighlightCol+1
                  , Item.Stuff (emphasizer (spaces 1))
                    :: Item.Spaces (nextHighlightCol-currCol)
                    :: acc
                  )
              end)
        in
          acc
        end


      fun newlineWithEndDebugs endDebugs startDebugs acc =
        if List.null endDebugs then
          (startDebugs, acc)
        else
        let
          val orderedStarts =
            Mergesort.sort sentryCmp (Seq.fromList startDebugs)
          val orderedEnds =
            Mergesort.sort eentryCmp (Seq.fromList endDebugs)

          val _ =
            print ("newLineWithEndDebugs:\n"
                   ^ "  starts: " ^ Seq.toString sentrytos orderedStarts ^ "\n"
                   ^ "  ends: " ^ Seq.toString eentrytos orderedEnds ^ "\n")

          (* This is a bit cumbersome, but actually is fairly straightforward:
           * for each `(info, col)` in `EE`, output `info` at column `col`.
           *
           * There's some trickiness though, because multiple `(info, col)`
           * entries might overlap. For this, we check if each entry fits,
           * and if not, we add the entry to `didntFit`, and then process
           * `didntFit` on the next line, repeating until all entries have been
           * output.
           *
           * Update: and now there's more trickiness, because we need to filter
           * starts as we go to get decent output...
           *)
          fun loop
                (i, SS: sentry Seq.t)
                (j, EE: eentry Seq.t)
                (didntFitEE: eentry list)
                ( removedSSCurrLine: sentry list
                , remainingSS: sentry list
                )
                (currCol: int)
                (accCurrLine: item list)
                (acc: item list)
            =
            if j >= Seq.length EE then
              if List.null didntFitEE then
                let
                  val remainingSS' = Seq.toList (Seq.drop SS i) @ remainingSS
                in
                  ( remainingSS'
                  , highlightActive accCurrLine acc (removedSSCurrLine @ remainingSS')
                  )
                end
              else
                loop
                  (0, Seq.append (Seq.fromRevList remainingSS, Seq.drop SS i))
                  (0, Seq.fromRevList didntFitEE)
                  []        (* didntFitEE *)
                  ([], [])  (* (removedSSCurrLine, remainingSS) *)
                  0         (* currCol *)
                  []        (* accCurrLine *)
                  (Item.Newline :: highlightActive accCurrLine acc
                    (Seq.toList (Seq.drop SS i) @ remainingSS @ removedSSCurrLine))
            else
            let
              val sentry = Seq.nth SS i
              val eentry = Seq.nth EE j

              val scol = sentryCol sentry
              val ecol = eentryCol eentry
              val info = sentryInfo sentry

              val _ =
                (* check invariant *)
                if scol <= ecol then ()
                else
                  ( print ("sentry " ^ sentrytos sentry ^ "\n"
                         ^ "eentry " ^ eentrytos eentry ^ "\n"
                         ^ "i " ^ Int.toString i ^ "\n"
                         ^ "j " ^ Int.toString j ^ "\n"
                         ^ "SS " ^ Seq.toString sentrytos SS ^ "\n"
                         ^ "EE " ^ Seq.toString eentrytos EE ^ "\n")
                  ; raise Fail "newlineWithEndDebugs.loop: invariant violated"
                  )
            in
              if scol < ecol orelse not (matchingStartEndEntries (sentry, eentry)) then
                loop (i+1, SS) (j, EE) didntFitEE (removedSSCurrLine, sentry :: remainingSS) currCol accCurrLine acc
              else if ecol < currCol then
                loop (i+1, SS) (j+1, EE) (eentry :: didntFitEE) (removedSSCurrLine, sentry :: remainingSS) currCol accCurrLine acc
              else
                let
                  val numSpaces = ecol - currCol
                  val newCol = currCol + numSpaces + CustomString.size info
                in
                  loop (i+1, SS) (j+1, EE) didntFitEE (sentry :: removedSSCurrLine, remainingSS) newCol (Item.Stuff info :: Item.Spaces numSpaces :: accCurrLine) acc
                end
            end

          val (remainingSS, acc) =
            loop (0, orderedStarts) (0, orderedEnds) [] ([], []) 0 [] (Item.Newline :: acc)

          val acc = highlightActive [] (Item.Newline :: acc) remainingSS
        in
          (remainingSS, acc)
        end


      fun processItem (item, (accCurrLine, acc, endDebugs, startDebugs)) =
        case item of
          Item.EndDebug entry => (accCurrLine, acc, entry :: endDebugs, startDebugs)
        | Item.StartDebug entry => (accCurrLine, acc, endDebugs, entry :: startDebugs)
        | Item.Newline =>
            let
              val (remainingSS, acc) =
                newlineWithEndDebugs endDebugs startDebugs
                  (highlightActive accCurrLine acc startDebugs)
            in
              ([], Item.Newline :: acc, [], remainingSS)
            end
        | _ => (item :: accCurrLine, acc, endDebugs, startDebugs)


      val init = ([], [], [], [])
      val init = processItem (Item.StartDebug (StartMaxWidthHighlight {col=maxWidth}), init)
      val (accCurrLine, acc, endDebugs, startDebugs) =
        List.foldr processItem init
          (Item.EndDebug (EndMaxWidthHighlight {col=maxWidth}) :: items)
    in
      if List.null endDebugs then
        accCurrLine @ acc
      else
        #2 (newlineWithEndDebugs endDebugs startDebugs
              (highlightActive accCurrLine acc startDebugs))
    end


  (* ====================================================================== *)
  (* ====================================================================== *)
  (* ====================================================================== *)


  fun revAndStripTrailingWhitespace (items: item list) =
    let
      fun loopStrip acc items =
        case items of
          [] => acc
        | Item.Spaces _ :: items' =>
            loopStrip acc items'
        | _ =>
            loopKeep acc items

      and loopKeep acc items =
        case items of
          [] => acc
        | Item.Newline :: items' =>
            loopStrip (Item.Newline :: acc) items'
        | x :: items' =>
            loopKeep (x :: acc) items'
    in
      loopStrip [] items
    end


  exception DoPromote of tab


  fun pretty {ribbonFrac, maxWidth, indentWidth, debug} doc =
    let
      val ribbonWidth =
        Int.max (0, Int.min (maxWidth,
          Real.round (ribbonFrac * Real.fromInt maxWidth)))

      val newline = CustomString.fromString "\n"
      val sp = CustomString.fromString " "

      val allTabs = allTabsInDoc doc
      val _ =
        if List.all (fn t => Tab.getState t = Tab.Fresh) allTabs then ()
        else raise Fail "PrettyTabbedDoc.pretty: bug: non-fresh input tab"

      (* initially, all tabs inactive, and their placement is unknown *)
      val _ = List.app (fn t => Tab.setState t (Tab.Usable Tab.Flattened)) allTabs

      (* tab -> hit first break? *)
      type debug_state = bool TabDict.t

      (* debug state, current tab, current 'at's, line start, current col, accumulator *)
      datatype layout_state =
        LS of
          debug_state *
          tab *
          TabSet.t *
          int *
          int *
          (item list)

      fun dbgInsert tab (LS (dbgState, ct, cats, s, c, a): layout_state) : layout_state =
        if not debug then
          LS (dbgState, ct, cats, s, c, a)
        else
          LS
            ( TabDict.insert dbgState (tab, false)
            , ct, cats, s, c, a
            )

      fun dbgBreak tab (LS (dbgState, ct, cats, s, c, a): layout_state) : layout_state =
        if not debug then
          LS (dbgState, ct, cats, s, c, a)
        else if TabDict.lookup dbgState tab then
          LS (dbgState, ct, cats, s, c, a)
        else
          LS
            ( TabDict.insert dbgState (tab, true)
            , ct, cats, s, c
            , Item.StartDebug (StartTabHighlight {tab = tab, col = c}) :: a
            )

      fun isPromotable' t =
        case Tab.getState t of
          Tab.Usable Tab.Flattened => true
        | Tab.Usable (Tab.Activated NONE) => true
        | Tab.Usable (Tab.Activated (SOME ti)) =>
            (case Tab.parent t of
              NONE => false
            | SOME p =>
                case Tab.getState p of
                  Tab.Usable (Tab.Activated (SOME pi)) =>
                    ti > pi + Int.max (indentWidth, Tab.minIndent t)
                | _ => raise Fail "PrettyTabbedDoc.pretty.isPromotable: bad parent tab")
        | _ => raise Fail "PrettyTabbedDoc.pretty.isPromotable: bad tab"


      fun isPromotable t =
        let
          val result = isPromotable' t
        in
          if not debug then () else
          print ("PrettyTabbedDoc.debug: isPromotable " ^ Tab.infoString t ^ " = " ^ (if result then "true" else "false") ^ "\n");
          result
        end


      fun oldestPromotableParent t =
        if not (isPromotable t) then NONE else
        case Tab.parent t of
          SOME p =>
            if not (isPromotable p) then
              SOME t
            else
              oldestPromotableParent p
        | NONE => SOME t


      fun oldestInactiveParent t =
        if Tab.isActivated t then NONE else
        case Tab.parent t of
          SOME p =>
            if Tab.isActivated p then
              SOME t
            else
              oldestInactiveParent p
        | NONE => SOME t


      (* Below, the `check` function is used to check for layout violations.
       * If any layout constraints are violated, it tries to promote a tab.
       *
       * The promotion strategy implemented here is simple: we always promote
       * the outermost promotable tab. This strategy prefers full promotion of
       * a tab before activating any of its children, which generally looks
       * pretty good.
       *
       * However, there is room for improvement.
       *
       * Consider this document with tabs labeled 0..3:
       *
       *   Functor (struct val x = 5 val y = 42 end)
       *   |       ||      |         |          |
       *   0       1|      3         3          2
       *            2
       *
       * Then under the current strategy, we could have the output
       * on the left, but not on the right:
       *
       *     possible layout   |  impossible layout
       *   --------------------+-------------------------
       *     Functor           |  Functor (struct
       *       (struct         |             val x = 5
       *          val x = 5    |             val y = 42
       *          val y = 42   |           end)
       *        end)           |
       *
       * The left layout is generated by the promotions [0,0,1,1,2,2,3,3].
       * (Notice in this sequence, each tab is repeated twice: the first
       * promotion activates the tab, and the second promotion relocates
       * the tab by placing it on a new line and indenting)
       *
       * If we instead had an alternative promotion strategy which allowed
       * for fully promoting a child before its parent, then it would be
       * possible to see the layout on the right. The promotion sequence
       * would need to be [0,0,1,2,3,3].
       *
       * UPDATE: tab styles (newly added) allow for some control over this.
       *)
      fun check (state as LS (dbgState, ct, cats, lnStart, col, acc)) =
        let
          val widthOkay = col <= maxWidth
          val ribbonOkay = (col - lnStart) <= ribbonWidth
          val okay = widthOkay andalso ribbonOkay

          val _ =
            if not debug orelse okay then ()
            else if not widthOkay then
              print ("PrettyTabbedDoc.debug: width violated: ct=" ^ Tab.infoString ct ^ " lnStart=" ^ Int.toString lnStart ^ " col=" ^ Int.toString col ^ "\n")
            else if not ribbonOkay then
              print ("PrettyTabbedDoc.debug: ribbon violated: ct=" ^ Tab.infoString ct ^ " lnStart=" ^ Int.toString lnStart ^ " col=" ^ Int.toString col ^ "\n")
            else
              print ("PrettyTabbedDoc.debug: unknown violation?? ct=" ^ Tab.infoString ct ^ " lnStart=" ^ Int.toString lnStart ^ " col=" ^ Int.toString col ^ "\n")
        in
          if okay then
            state
          else
          case oldestPromotableParent ct of
            (* TODO: FIXME: there's a bug here. Even if the current tab (ct)
             * doesn't have a promotable parent, there might be another
             * promotable tab on the same line.
             *
             * For example: tabs s and t occupy the same line; tab s is
             * fully promoted; tab t is inactive because it fits within the
             * max width. After completing tab t, we return to tab s, and then
             * get a width violation. However, tab s (the current tab) has
             * no promotable parent.
             *
             *   sssssssssstttttttttsss|s
             *   ^         ^           ^
             *   tab s:    tab t:      max width
             *   fully     inactive
             *   promoted
             *
             * The fix in the above example is to promote tab t. So, perhaps
             * we need to keep track of a set of promotable tabs on the
             * current line and then choose one to promote (?)
             *)
            SOME p => raise DoPromote p
          | NONE => state
        end


      fun putItemSameLine state item =
        let
          val LS (dbgState, ct, _, lnStart, col, acc) = state
        in
          check (LS
            ( dbgState
            , ct
            (* an item has been placed, so now we are no longer at a tab *)
            , TabSet.empty
            , lnStart
            , col + Item.width item
            , item :: acc
            ))
        end

      fun parentTabCol tab =
        case Tab.parent tab of
          NONE => raise Fail "PrettyTabbedDoc.pretty.parentTabCol: no parent"
        | SOME p =>
        case Tab.getState p of
          Tab.Usable (Tab.Activated (SOME i)) => i
        | _ => raise Fail "PrettyTabbedDoc.pretty.parentTabCol: bad tab"


      fun ensureAt tab state =
        let
          val LS (dbgState, ct, cats, lnStart, col, acc) = state
          val alreadyAtTab = TabSet.contains cats tab

          fun goto i =
            if alreadyAtTab then
              dbgBreak tab (LS (dbgState, tab, cats, lnStart, i, acc))
            else if i = col andalso Tab.isInplace tab then
              dbgBreak tab (LS (dbgState, tab, TabSet.insert cats tab, lnStart, i, acc))
            else if i < col then
              dbgBreak tab (check (LS
                ( dbgState
                , tab
                , TabSet.singleton tab
                , i
                , i
                , Item.Spaces i :: Item.Newline :: acc)
                ))
            else if isPromotable tab then
              (* force this tab to promote if possible, which should move
                * it onto a new line and indent. *)
              raise DoPromote tab
            else if lnStart < i then

              (* SAM_NOTE: TODO: This case might be unnecessary... we can use
               * tab styles (inplace vs indented) to resolve this issue. Inplace
               * can be allowed to advance, and indented require a fresh line.
               * This would simplify the logic above, too; the case where
               *   i = col andalso Tab.isInplace tab
               * would just be a special case of advancing on the current line.
               *)

              (* This avoids advancing the current line to meet the tab,
               * if possible, which IMO results in strange layouts. *)
              dbgBreak tab (check (LS
                ( dbgState
                , tab
                , if i = col then TabSet.insert cats tab else TabSet.singleton tab
                , i
                , i
                , Item.Spaces i :: Item.Newline :: acc)
                ))
            else
              (* Fall back on advancing the current line to meet the tab,
               * which is a little strange, but better than nothing. *)
              dbgBreak tab (check (LS
                ( dbgState
                , tab
                , if i = col then TabSet.insert cats tab else TabSet.singleton tab
                , lnStart
                , i
                , Item.Spaces (i-col) :: acc)
                ))

          val state' =
            case Tab.getState tab of
              Tab.Usable Tab.Flattened =>
                if Tab.isRigid tab then
                  raise DoPromote (valOf (oldestPromotableParent tab))
                else
                  LS (dbgState, tab, cats, lnStart, col, acc)

            | Tab.Usable (Tab.Activated (SOME i)) =>
                goto i

            | Tab.Usable (Tab.Activated NONE) =>
                if Tab.isInplace tab then
                  if col < parentTabCol tab then
                    ( Tab.setState tab (Tab.Usable (Tab.Activated (SOME (parentTabCol tab))))
                    ; goto (parentTabCol tab)
                    )
                  else
                    ( Tab.setState tab (Tab.Usable (Tab.Activated (SOME col)))
                    ; goto col
                    )
                else
                  let
                    val i =
                      parentTabCol tab
                      + Int.max (indentWidth, Tab.minIndent tab)
                  in
                    Tab.setState tab (Tab.Usable (Tab.Activated (SOME i)));
                    goto i
                  end

            | _ =>
                raise Fail "PrettyTabbedDoc.pretty.Goto: bad tab"
        in
          state'
        end


      (* This is a little tricky, but the idea is: try to lay out the doc,
       * and keep track of whether or not there exists an ancestor tab that
       * could be promoted (ap). If we ever violate either the width or
       * ribbon condition, then promote the oldest ancestor tab and try again.
       *
       * Promotion is implemented by throwing an exception (DoPromote), which
       * is caught by the oldest ancestor.
       *)
      fun layout (state: layout_state) doc : layout_state =
        case doc of
          Empty =>
            state

        | Space =>
            putItemSameLine state (Item.Spaces 1)

        | Text s =>
            putItemSameLine state (Item.Stuff s)

        | Newline =>
            let
              val LS (dbgState, ct, cats, lnStart, col, acc) = state
            in
              check (LS (dbgState, ct, cats, col, col, Item.Spaces col :: Item.Newline :: acc))
            end

        | Concat (doc1, doc2) =>
            layout (layout state doc1) doc2

        | At (tab, doc) =>
            let
              val LS (_, origCurrentTab, _, _, _, _) = state
              val state' = ensureAt tab state
              val LS (dbgState, _, cats, lnStart, col, acc) = layout state' doc
            in
              LS (dbgState, origCurrentTab, cats, lnStart, col, acc)
            end

        | Cond {tab, inactive, active} =>
            let in
              case Tab.getState tab of
                Tab.Usable (Tab.Activated _) => layout state active
              | Tab.Usable Tab.Flattened => layout state inactive
              | _ => raise Fail "PrettyTabbedDoc.pretty.layout.Cond: bad tab"
            end

        | NewTab {parent, tab, doc} =>
            let
              fun tryPromote () =
                (* try to activate first *)
                if not (Tab.isActivated tab) then
                  Tab.setState tab (Tab.Usable (Tab.Activated NONE))
                else (* if activated, try to relocate *)
                case Tab.getState tab of
                  Tab.Usable (Tab.Activated NONE) =>
                    let
                      val desired =
                        parentTabCol tab
                        + Int.max (indentWidth, Tab.minIndent tab)
                    in
                      Tab.setState tab (Tab.Usable (Tab.Activated (SOME desired)))
                    end
                | Tab.Usable (Tab.Activated (SOME i)) =>
                    let
                      val desired =
                        Int.min
                          ( i
                          , parentTabCol tab
                            + Int.max (indentWidth, Tab.minIndent tab)
                          )
                    in
                      Tab.setState tab (Tab.Usable (Tab.Activated (SOME desired)))
                    end
                | _ =>
                    raise Fail "PrettyTabbedDoc.pretty.layout.NewTab.tryPromote: bad tab"

              fun doit () =
                let in
                  ( ()
                  ; (layout (dbgInsert tab state) doc
                      handle DoPromote p =>
                      if not (Tab.eq (p, tab)) then raise DoPromote p else
                      let
                        val _ =
                          if not debug then () else
                          print ("PrettyTabbedDoc.debug: promoting " ^ Tab.infoString tab ^ "\n")
                      in
                        tryPromote ();
                        doit ()
                      end)
                  )
                end

              val _ = Tab.setState tab (Tab.Usable Tab.Flattened)

              val LS (dbgState, _, cats, lnStart, col, acc) : layout_state =
                doit ()

              val acc =
                if not debug then acc else
                case Tab.getState tab of
                  Tab.Usable Tab.Flattened => acc
                | Tab.Usable (Tab.Activated NONE) => acc
                | Tab.Usable (Tab.Activated (SOME i)) =>
                    if TabDict.lookup dbgState tab then
                      Item.EndDebug (EndTabHighlight {tab = tab, col = i}) :: acc
                    else
                      acc
                | _ => raise Fail "PrettyTabbedDoc.debug: error..."
            in
              if not debug then () else
              print ("PrettyTabbedDoc.debug: finishing " ^ Tab.infoString tab ^ "\n");

              Tab.setState tab Tab.Completed;

              LS (dbgState, parent, TabSet.remove cats tab, lnStart, col, acc)
            end


      val init = LS (TabDict.empty, root, TabSet.singleton root, 0, 0, [])
      val init = dbgBreak Tab.Root (dbgInsert Tab.Root init)
      val LS (_, _, _, _, _, items) = layout init doc
      val items =
        if not debug then items
        else Item.EndDebug (EndTabHighlight {tab = Tab.Root, col = 0}) :: items

      val items = if not debug then items else implementDebugs maxWidth items

      (* reset tabs (so that if we call `pretty` again, it will work...) *)
      val _ = List.app (fn tab => Tab.setState tab Tab.Fresh) allTabs

      val items = revAndStripTrailingWhitespace items

      fun itemToString x =
        case x of
          Item.Newline => newline
        | Item.Spaces n => spaces n
        | Item.Stuff s => s
        | _ => raise Fail "impossible"
    in
      CustomString.concat (List.map itemToString items)
    end


  val toString = pretty {ribbonFrac = 0.5, maxWidth = 80, indentWidth = 2, debug = false}

end