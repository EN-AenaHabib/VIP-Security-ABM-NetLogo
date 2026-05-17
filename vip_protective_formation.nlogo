;;===========================================================================
;; Agent-Based Modeling of Protective Formation Strategies
;; for VIP Security Personnel in Dynamic High-Density Crowd Environments
;;
;; Model: vip_protective_formation.nlogo
;; Version: Alpha 1.0
;; Framework: NetLogo 6.x
;;
;; Agent Types:
;;   1. VIP          - the protected principal (1 agent)
;;   2. Bodyguard    - security personnel forming protective shell
;;   3. Civilian     - crowd members with social-force movement
;;   4. Threat       - hostile agent navigating toward VIP
;;===========================================================================

;; ─────────────────────────────────────────────────────────────
;;  BREED DECLARATIONS
;; ─────────────────────────────────────────────────────────────
breed [ vips        vip        ]
breed [ bodyguards  bodyguard  ]
breed [ civilians   civilian   ]
breed [ threats     threat     ]

;; ─────────────────────────────────────────────────────────────
;;  AGENT VARIABLES
;; ─────────────────────────────────────────────────────────────
vips-own [
  health            ;; 0-100, drops on threat proximity
  alert-level       ;; 0=normal 1=caution 2=emergency
  target-x          ;; destination x
  target-y          ;; destination y
  moving?           ;; is VIP walking to a target?
]

bodyguards-own [
  role              ;; "front" "rear" "left" "right" "lead" "tail"
  formation-x       ;; ideal formation offset-x from VIP
  formation-y       ;; ideal formation offset-y from VIP
  alert-level       ;; mirrors VIP alert level
  speed             ;; current speed
  threat-target     ;; agentset - nearest threat being watched
  intercepting?     ;; true when moving to block a threat
  intercept-x       ;; intercept destination
  intercept-y       ;; intercept destination
  stamina           ;; 100 = full; drains during intercept
]

civilians-own [
  desired-speed     ;; preferred walking speed
  actual-speed      ;; current speed (reduced in dense areas)
  heading-goal      ;; target heading (random walk + flow)
  panic-level       ;; 0-1; rises near threats/alerts
  density-here      ;; local crowd density
]

threats-own [
  aggression        ;; 0-1 how directly they approach VIP
  detected?         ;; has a bodyguard spotted this threat?
  blocked?          ;; is a bodyguard physically blocking path?
  speed             ;; current movement speed
  patience          ;; countdown before re-routing
]

patches-own [
  crowd-density     ;; 0-1 aggregate civilian density
  flow-x            ;; social force x-component for this patch
  flow-y            ;; social force y-component for this patch
  is-obstacle?      ;; wall / barrier cell
  heat              ;; visual heat-map value (decays)
]

;; ─────────────────────────────────────────────────────────────
;;  GLOBAL VARIABLES
;; ─────────────────────────────────────────────────────────────
globals [
  formation-type        ;; "diamond" "wedge" "box" "circle"
  vip-agent             ;; direct reference to the one VIP
  alert-color-normal    ;; color constants
  alert-color-caution
  alert-color-emergency
  num-threats-neutralised
  simulation-time
  avg-crowd-density
  formation-integrity   ;; 0-1 how well guards hold positions
]

;; ─────────────────────────────────────────────────────────────
;;  FORMATION OFFSET TABLES  (x y pairs per role)
;; ─────────────────────────────────────────────────────────────
;;  Diamond  : lead front-L front-R rear
;;  Wedge    : lead left right rear-L rear-R
;;  Box      : front-L front-R rear-L rear-R
;;  Circle   : 6 evenly-spaced agents
;; ─────────────────────────────────────────────────────────────

to-report formation-offsets [ ftype role-index ]
  ;; Returns [dx dy] list for a given formation type and guard index (0-based)
  let offsets []
  if ftype = "diamond" [
    set offsets [
      [ 0  2.5 ]   ;; 0 lead
      [-1.5 1 ]    ;; 1 front-left
      [ 1.5 1 ]    ;; 2 front-right
      [ 0 -2.5 ]   ;; 3 rear
      [-1.5 -1]    ;; 4 rear-left  (extra guards)
      [ 1.5 -1]    ;; 5 rear-right
    ]
  ]
  if ftype = "wedge" [
    set offsets [
      [ 0   3  ]   ;; 0 apex
      [-2   1.5]   ;; 1 left-wing
      [ 2   1.5]   ;; 2 right-wing
      [-1  -1.5]   ;; 3 rear-left
      [ 1  -1.5]   ;; 4 rear-right
      [ 0  -3  ]   ;; 5 tail
    ]
  ]
  if ftype = "box" [
    set offsets [
      [-2   2  ]   ;; 0 front-left
      [ 2   2  ]   ;; 1 front-right
      [-2  -2  ]   ;; 2 rear-left
      [ 2  -2  ]   ;; 3 rear-right
      [ 0   2.5]   ;; 4 front-center
      [ 0  -2.5]   ;; 5 rear-center
    ]
  ]
  if ftype = "circle" [
    ;; 6 guards evenly on a circle of radius 2.5
    let r 2.5
    set offsets (list
      (list (r * sin   0)  (r * cos   0))
      (list (r * sin  60)  (r * cos  60))
      (list (r * sin 120)  (r * cos 120))
      (list (r * sin 180)  (r * cos 180))
      (list (r * sin 240)  (r * cos 240))
      (list (r * sin 300)  (r * cos 300))
    )
  ]
  if role-index >= length offsets [ report [0 0] ]
  report item role-index offsets
end

;; ─────────────────────────────────────────────────────────────
;;  SETUP
;; ─────────────────────────────────────────────────────────────
to setup
  clear-all

  ;; Color constants
  set alert-color-normal    [50 205 50]    ;; lime green
  set alert-color-caution   [255 165 0]    ;; orange
  set alert-color-emergency [220 20 60]    ;; crimson

  set num-threats-neutralised 0
  set simulation-time 0
  set formation-type selected-formation

  setup-environment
  setup-vip
  setup-bodyguards
  setup-civilians
  setup-threats

  update-formation-offsets
  reset-ticks
end

;; ─────────────────────────────────────────────────────────────
;;  ENVIRONMENT
;; ─────────────────────────────────────────────────────────────
to setup-environment
  ask patches [
    set is-obstacle? false
    set crowd-density 0
    set heat 0
    set flow-x 0
    set flow-y 0
    set pcolor 28    ;; tan/crowd colour
  ]

  ;; Draw walls / barriers along edges
  ask patches with [ pxcor = min-pxcor or pxcor = max-pxcor
                  or pycor = min-pycor or pycor = max-pycor ] [
    set is-obstacle? true
    set pcolor 5     ;; dark gray
  ]

  ;; Internal obstacle columns (simulate corridor pillars)
  if use-obstacles? [
    let obstacle-list (list
      [15 10] [15 -10] [-15 10] [-15 -10]
      [5 18]  [5 -18]  [-5 18]  [-5 -18]
    )
    foreach obstacle-list [ pos ->
      let ox item 0 pos
      let oy item 1 pos
      ask patches with [ abs (pxcor - ox) <= 1 and abs (pycor - oy) <= 1 ] [
        set is-obstacle? true
        set pcolor 5
      ]
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  VIP
;; ─────────────────────────────────────────────────────────────
to setup-vip
  create-vips 1 [
    set size 2.2
    set color yellow
    set shape "person"
    setxy 0 0
    set health 100
    set alert-level 0
    set moving? true
    ;; VIP walks toward a random destination, loops
    set target-x (random 30 - 15)
    set target-y (random 30 - 15)
    set vip-agent self
    set label "VIP"
    set label-color white
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  BODYGUARDS
;; ─────────────────────────────────────────────────────────────
to setup-bodyguards
  let roles ["lead" "front-L" "front-R" "rear" "rear-L" "rear-R"]
  let idx 0
  create-bodyguards num-bodyguards [
    set size 1.8
    set color scale-color blue 0.5 0 1
    set shape "person"
    set role item (idx mod 6) roles
    let offsets formation-offsets formation-type idx
    let ox item 0 offsets
    let oy item 1 offsets
    set formation-x ox
    set formation-y oy
    setxy ([xcor] of vip-agent + ox)
          ([ycor] of vip-agent + oy)
    set alert-level 0
    set speed guard-base-speed
    set intercepting? false
    set stamina 100
    set idx idx + 1
    set label-color white
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  CIVILIANS
;; ─────────────────────────────────────────────────────────────
to setup-civilians
  create-civilians num-civilians [
    set size 1.2
    set color [180 180 180]       ;; light gray
    set shape "person"
    ;; Scatter randomly avoiding walls
    let placed? false
    while [ not placed? ] [
      setxy (random 58 - 29) (random 58 - 29)
      if not [is-obstacle?] of patch-here [ set placed? true ]
    ]
    set desired-speed (0.3 + random-float 0.4)
    set actual-speed desired-speed
    set heading-goal random 360
    set panic-level 0
    set density-here 0
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  THREATS
;; ─────────────────────────────────────────────────────────────
to setup-threats
  create-threats num-threats [
    set size 1.6
    set color red
    set shape "person"
    ;; Spawn at world edge
    let placed? false
    while [ not placed? ] [
      setxy (random 58 - 29) (random 58 - 29)
      if not [is-obstacle?] of patch-here
         and distance vip-agent > 20 [ set placed? true ]
    ]
    set aggression (0.4 + random-float 0.5)
    set detected? false
    set blocked? false
    set speed threat-base-speed
    set patience 30
    set label "!"
    set label-color black
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  FORMATION OFFSET UPDATE  (call when formation-type changes)
;; ─────────────────────────────────────────────────────────────
to update-formation-offsets
  let idx 0
  ask bodyguards [
    let offsets formation-offsets formation-type idx
    set formation-x item 0 offsets
    set formation-y item 1 offsets
    set idx idx + 1
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  GO  (main loop)
;; ─────────────────────────────────────────────────────────────
to go
  if not any? vips [ stop ]

  set simulation-time simulation-time + 1

  ;; Synchronise formation type from UI slider each tick
  if formation-type != selected-formation [
    set formation-type selected-formation
    update-formation-offsets
  ]

  ;; === Patch dynamics ===
  update-patch-density
  diffuse-heat

  ;; === Agent step ===
  move-vip
  move-bodyguards
  move-civilians
  move-threats

  ;; === Interactions ===
  detect-threats
  intercept-threats
  check-threat-contact

  ;; === Alert propagation ===
  propagate-alert

  ;; === Metrics ===
  compute-formation-integrity
  set avg-crowd-density mean [crowd-density] of patches

  ;; === Visualization ===
  color-agents
  update-patch-colors

  tick
end

;; ─────────────────────────────────────────────────────────────
;;  PATCH DYNAMICS
;; ─────────────────────────────────────────────────────────────
to update-patch-density
  ask patches [ set crowd-density 0 ]
  ask civilians [
    ask patch-here [
      set crowd-density crowd-density + 0.15
      set heat heat + 0.3
    ]
  ]
  ;; Smooth density via diffuse
  diffuse crowd-density 0.3
  ask patches [ set crowd-density min list 1 crowd-density ]
end

to diffuse-heat
  diffuse heat 0.05
  ask patches [ set heat heat * 0.96 ]
end

;; ─────────────────────────────────────────────────────────────
;;  VIP MOVEMENT  (goal-directed + obstacle avoidance)
;; ─────────────────────────────────────────────────────────────
to move-vip
  ask vips [
    ;; Pick a new target if close enough
    if distancexy target-x target-y < 3 [
      set target-x (random 40 - 20)
      set target-y (random 40 - 20)
    ]

    ;; Move slower during emergency
    let spd vip-base-speed
    if alert-level = 1 [ set spd spd * 0.8 ]
    if alert-level = 2 [ set spd spd * 0.5 ]

    face-safely target-x target-y
    forward spd
  ]
end

to face-safely [ tx ty ]
  ;; Turn toward target; if next patch is obstacle, try side-steps
  face patch tx ty
  if [is-obstacle?] of patch-ahead 1 [
    rt 45
    if [is-obstacle?] of patch-ahead 1 [ lt 90 ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  BODYGUARD MOVEMENT
;; ─────────────────────────────────────────────────────────────
to move-bodyguards
  ask bodyguards [
    ;; Mirror VIP alert level
    set alert-level [alert-level] of vip-agent

    ifelse intercepting? [
      ;; Move to intercept position
      face patch intercept-x intercept-y
      let dist-to-intercept distancexy intercept-x intercept-y
      ifelse dist-to-intercept < 1 [
        set intercepting? false
        set speed guard-base-speed
      ] [
        set speed guard-base-speed * 1.4   ;; sprint
        forward speed
      ]
      set stamina max list 0 (stamina - 0.5)
    ] [
      ;; Return to formation slot
      let ideal-x [xcor] of vip-agent + formation-x
      let ideal-y [ycor] of vip-agent + formation-y
      let dist-to-slot distancexy ideal-x ideal-y

      ifelse dist-to-slot > 0.5 [
        face patch ideal-x ideal-y
        set speed guard-base-speed
        forward min list speed dist-to-slot
      ] [
        ;; In slot – face same direction as VIP
        set heading [heading] of vip-agent
      ]

      ;; Stamina recovery
      set stamina min list 100 (stamina + 0.2)
    ]

    ;; Obstacle avoidance
    if [is-obstacle?] of patch-here [
      rt 180
      forward 1
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  CIVILIAN MOVEMENT  (Social Force Model – simplified)
;; ─────────────────────────────────────────────────────────────
to move-civilians
  ask civilians [
    ;; Density slows movement
    set density-here [crowd-density] of patch-here
    set actual-speed desired-speed * (1 - 0.6 * density-here)

    ;; Panic: flee from threats
    let near-threat threats in-radius 8
    if any? near-threat [
      set panic-level min list 1 (panic-level + 0.05)
      face min-one-of near-threat [distance myself]
      rt 180       ;; flee
    ]
    if not any? near-threat [
      set panic-level max list 0 (panic-level - 0.01)
    ]

    ;; Panic overrides normal walk: run away
    ifelse panic-level > 0.3 [
      forward actual-speed * 1.5
    ] [
      ;; Normal random-walk with persistence
      set heading-goal heading-goal + (random 21 - 10)
      set heading heading-goal
      forward actual-speed
    ]

    ;; Wall bounce
    if [is-obstacle?] of patch-here [
      rt 180 + random 90 - 45
      forward 0.5
    ]
    ;; Stay in bounds
    if abs xcor > 28 or abs ycor > 28 [ setxy 0 (random 20 - 10) ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  THREAT MOVEMENT
;; ─────────────────────────────────────────────────────────────
to move-threats
  ask threats [
    if blocked? [ set patience patience - 1 ]
    if patience <= 0 [
      set blocked? false
      set patience 30
      ;; Re-route: try a flanking angle
      rt 60 + random 60
    ]

    ifelse blocked? [
      ;; Jitter in place trying to get through
      rt random 20 - 10
      forward speed * 0.3
    ] [
      ;; Navigate toward VIP mixing direct and random components
      let direct-heading towards vip-agent
      let noise random 30 - 15
      set heading (aggression * direct-heading + (1 - aggression) * (heading + noise))
      forward speed
    ]

    ;; Obstacle avoidance
    if [is-obstacle?] of patch-here [
      rt 180 + random 40 - 20
      forward 1
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  THREAT DETECTION
;; ─────────────────────────────────────────────────────────────
to detect-threats
  ask bodyguards [
    let visible-threats threats in-radius detection-radius
    set threat-target visible-threats
    ask visible-threats [
      set detected? true
      set color [255 60 0]   ;; orange-red when detected
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  INTERCEPT LOGIC
;; ─────────────────────────────────────────────────────────────
to intercept-threats
  ask bodyguards [
    if any? threat-target and not intercepting? [
      let nearest-threat min-one-of threat-target [distance myself]
      if nearest-threat != nobody [
        let tx [xcor] of nearest-threat
        let ty [ycor] of nearest-threat
        ;; Only one guard per threat intercepts (closest)
        let closest-guard min-one-of bodyguards [distance nearest-threat]
        if self = closest-guard [
          set intercepting? true
          ;; Aim for midpoint between VIP and threat
          set intercept-x ([xcor] of vip-agent + tx) / 2
          set intercept-y ([ycor] of vip-agent + ty) / 2
          ask nearest-threat [ set blocked? true ]
        ]
      ]
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  THREAT CONTACT CHECK
;; ─────────────────────────────────────────────────────────────
to check-threat-contact
  ask vips [
    let close-threats threats in-radius 2
    if any? close-threats [
      set health max list 0 (health - 5)
      set alert-level 2
      if health <= 0 [
        output-print "VIP HEALTH CRITICAL — simulation ends"
        stop
      ]
    ]
  ]

  ;; Bodyguard neutralises threat on contact
  ask bodyguards [
    let contact-threats threats in-radius 1.5
    ask contact-threats [
      set num-threats-neutralised num-threats-neutralised + 1
      die
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  ALERT PROPAGATION
;; ─────────────────────────────────────────────────────────────
to propagate-alert
  ask vips [
    ;; Raise alert if any threat detected within 15 units
    let threats-near threats in-radius 15
    ifelse any? threats-near [
      ifelse any? (threats in-radius 6) [
        set alert-level 2
      ] [
        set alert-level 1
      ]
    ] [
      ;; Slowly de-escalate
      if alert-level > 0 and (ticks mod 30 = 0) [
        set alert-level alert-level - 1
      ]
    ]
  ]

  ;; Sync bodyguard alert levels
  ask bodyguards [
    set alert-level [alert-level] of vip-agent
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  FORMATION INTEGRITY METRIC
;; ─────────────────────────────────────────────────────────────
to compute-formation-integrity
  if not any? bodyguards [ set formation-integrity 0  stop ]
  let total-deviation 0
  ask bodyguards [
    let ideal-x [xcor] of vip-agent + formation-x
    let ideal-y [ycor] of vip-agent + formation-y
    set total-deviation total-deviation + distancexy ideal-x ideal-y
  ]
  let avg-deviation total-deviation / count bodyguards
  ;; Integrity 1.0 = perfect; decays with avg deviation
  set formation-integrity max list 0 (1 - avg-deviation / 10)
end

;; ─────────────────────────────────────────────────────────────
;;  VISUALIZATION
;; ─────────────────────────────────────────────────────────────
to color-agents
  ;; VIP color by alert level
  ask vips [
    if alert-level = 0 [ set color yellow ]
    if alert-level = 1 [ set color orange ]
    if alert-level = 2 [ set color red    ]
    set label (word "VIP ♥" round health)
  ]

  ;; Bodyguards
  ask bodyguards [
    if alert-level = 0 [ set color [30 144 255]  ]   ;; dodger blue
    if alert-level = 1 [ set color [255 140 0]   ]   ;; dark orange
    if alert-level = 2 [ set color [220 20 60]   ]   ;; crimson
    if intercepting?   [ set color [0 255 127]   ]   ;; spring green
    set label (word round stamina "%")
  ]

  ;; Civilians: color by panic
  ask civilians [
    let p panic-level
    set color (list (55 + round (200 * p)) (55 + round (100 * (1 - p))) 55)
  ]

  ;; Threats: pulse red/orange
  ask threats [
    ifelse ticks mod 10 < 5
      [ set color red ]
      [ set color orange ]
    if detected? [ set color [255 0 128] ]   ;; magenta when spotted
  ]
end

to update-patch-colors
  ask patches [
    ifelse is-obstacle? [
      set pcolor 5
    ] [
      ifelse show-heat-map? [
        ;; Heat map overlay
        let h min list 1 heat
        set pcolor (list (round (50 + 150 * h)) (round (30 * (1 - h))) 30)
      ] [
        ;; Density map
        let d crowd-density
        set pcolor (list (round (40 + 80 * d)) (round (40 + 30 * (1 - d))) 40)
      ]
    ]
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  REPORTERS  (for BehaviorSpace / plots)
;; ─────────────────────────────────────────────────────────────
to-report vip-health
  if not any? vips [ report 0 ]
  report [health] of vip-agent
end

to-report vip-alert
  if not any? vips [ report 0 ]
  report [alert-level] of vip-agent
end

to-report threats-remaining
  report count threats
end

to-report guards-intercepting
  report count bodyguards with [intercepting?]
end

;; ─────────────────────────────────────────────────────────────
;;  INTERFACE PROCEDURE  (button: Change Formation)
;; ─────────────────────────────────────────────────────────────
to change-formation
  set formation-type selected-formation
  update-formation-offsets
end

to spawn-threat
  create-threats 1 [
    set size 1.6
    set color red
    set shape "person"
    let placed? false
    while [ not placed? ] [
      setxy (random 58 - 29) (random 58 - 29)
      if not [is-obstacle?] of patch-here
         and distance vip-agent > 18 [ set placed? true ]
    ]
    set aggression (0.5 + random-float 0.5)
    set detected? false
    set blocked? false
    set speed threat-base-speed * (0.9 + random-float 0.2)
    set patience 30
    set label "!"
    set label-color black
  ]
end

;; ─────────────────────────────────────────────────────────────
;;  END OF MODEL
;; ─────────────────────────────────────────────────────────────
@#$#@#$#@
GRAPHICS-WINDOW
210
10
748
549
-1
-1
9.0
1
12
1
1
1
0
0
0
1
-29
29
-29
29
1
1
1
ticks
30.0

BUTTON
10
10
100
44
Setup
setup
NIL
1
T
OBSERVER
NIL
S
NIL
NIL
1

BUTTON
105
10
200
44
Go
go
T
1
T
OBSERVER
NIL
G
NIL
NIL
1

SLIDER
10
55
200
88
num-bodyguards
num-bodyguards
1
6
6.0
1
1
NIL
HORIZONTAL

SLIDER
10
95
200
128
num-civilians
num-civilians
10
300
120.0
10
1
NIL
HORIZONTAL

SLIDER
10
135
200
168
num-threats
num-threats
0
10
3.0
1
1
NIL
HORIZONTAL

SLIDER
10
175
200
208
vip-base-speed
vip-base-speed
0.05
0.5
0.15
0.05
1
NIL
HORIZONTAL

SLIDER
10
215
200
248
guard-base-speed
guard-base-speed
0.1
0.8
0.25
0.05
1
NIL
HORIZONTAL

SLIDER
10
255
200
288
threat-base-speed
threat-base-speed
0.05
0.5
0.2
0.05
1
NIL
HORIZONTAL

SLIDER
10
295
200
328
detection-radius
detection-radius
3
15
10.0
1
1
NIL
HORIZONTAL

CHOOSER
10
335
200
380
selected-formation
selected-formation
"diamond" "wedge" "box" "circle"
0

BUTTON
10
385
200
418
Change Formation
change-formation
NIL
1
T
OBSERVER
NIL
F
NIL
NIL
1

BUTTON
10
425
200
458
Spawn Threat
spawn-threat
NIL
1
T
OBSERVER
NIL
T
NIL
NIL
1

SWITCH
10
465
130
498
use-obstacles?
use-obstacles?
0
1
-1000

SWITCH
135
465
200
498
show-heat-map?
show-heat-map?
1
1
-1000

MONITOR
760
10
900
55
VIP Health
vip-health
1
1
11

MONITOR
760
60
900
105
Alert Level
vip-alert
0
1
11

MONITOR
760
110
900
155
Threats Remaining
threats-remaining
0
1
11

MONITOR
760
160
900
205
Threats Neutralised
num-threats-neutralised
0
1
11

MONITOR
760
210
900
255
Formation Integrity
formation-integrity
2
1
11

MONITOR
760
260
900
305
Guards Intercepting
guards-intercepting
0
1
11

MONITOR
760
310
900
355
Avg Crowd Density
avg-crowd-density
3
1
11

MONITOR
760
360
900
405
Simulation Time
simulation-time
0
1
11

PLOT
760
420
1020
570
VIP Health Over Time
Time
Health
0.0
200.0
0.0
100.0
true
false
"" ""
PENS
"health" 1.0 0 -13840069 true "" "plot vip-health"
"alert" 1.0 0 -2674135 true "" "plot vip-alert * 33"

PLOT
1025
420
1285
570
Formation Integrity
Time
Integrity
0.0
200.0
0.0
1.0
true
false
"" ""
PENS
"integrity" 1.0 0 -13791810 true "" "plot formation-integrity"

PLOT
760
575
1020
720
Threat Count
Time
Count
0.0
200.0
0.0
15.0
true
false
"" ""
PENS
"threats" 1.0 0 -2674135 true "" "plot threats-remaining"
"neutralised" 1.0 0 -10899396 true "" "plot num-threats-neutralised"

TEXTBOX
10
510
200
560
LEGEND:\nYellow = VIP  Blue = Guard\nRed = Threat  Gray = Civilian\nGreen = Intercepting Guard
10
0.0
1

@#$#@#$#@
NETLOGO-VERSION
6.3.0
@#$#@#$#@
