val x =
  ( 1: int
  , Array.modify (~ : int -> int) (Array.array (10, 100))
  , Int.toString 1
  , 5 - 6 * 7 + 8 div 9
  , op+ (100, 1000)
  , List.filter (fn x => x mod 2 = 0) (List.tabulate (100, fn i => i))
  , fn 0 => 1 | 1 => 2 | 2 => 3 | 3 => 4 | 4 => 5 | _ => ~1
  , true orelse false andalso true
  , true andalso false orelse true
  , raise Subscript
  , 1 + (raise Fail "Exceptions can be raised anywhere")
  , raise Subscript handle Subscript => "whoa" | Option => "yo"
  , case 0 of
      0 => "this is a very long story"
    | 1 => "about a guy named joe"
    | 2 => "and his mama"
    | 3 => "whose name is jo"
  , case 0 of 0 => 1 | 1 => 2 | 2 => 3
  , case 0 of
      0 => "short string"
    | 1 => String.concatWith "\n" (List.tabulate (100, fn i => Int.toString i))
    | 2 => "uhhh"
  )
