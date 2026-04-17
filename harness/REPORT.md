# mac-cua-mcp harness report
Generated: 2026-04-18T05:04:42

**8/8 suites passed** in 295.6s

| suite | status | duration |
| --- | --- | --- |
| core tools (9) (core_tools.py) | ✅ pass | 65.5s |
| error contract (4) (test_error_contract.py) | ✅ pass | 4.9s |
| press_key vocab (25) (test_press_key_vocab.py) | ✅ pass | 145.2s |
| perf bench (4 apps) (test_perf.py) | ✅ pass | 19.0s |
| input latency (2 ops) (test_input_latency.py) | ✅ pass | 20.5s |
| stability (100 calls) (test_stability.py) | ✅ pass | 28.1s |
| concurrency (2 agents) (test_concurrency.py) | ✅ pass | 1.6s |
| workflow (5-step calc) (test_workflow.py) | ✅ pass | 10.9s |

## Suite outputs

### core tools (9)

```
MAC'

[perform_secondary_action Raise]
  [32mPASS[0m  sky accepted=True ({'text': 'App=com.apple.calculator (pid 20926)\nWindow: "Calculator", App: Calcu)  mac accepted=True ({'text': 'ok'})

[drag - verify event sequence is accepted]
  [32mPASS[0m  sky accepted=True  mac accepted=True

[1m=== summary ===[0m
  [32mPASS[0m  list_apps: common=16  only_sky=8  only_mac=0
  [32mPASS[0m  get_app_state: sky_nodes=24 mac_nodes=18  both-see-scroll-area=True
  [32mPASS[0m  scroll_textedit: sky: 0.0→0.587371512482 (ok)  mac: 0.0→0.186000978953 (ok)
  [32mPASS[0m  press_key: sky="tree-has-100=True  disp='338638.81578947'  (rejects=0)"  mac="tree-has-100=True  disp='338638.81578947'  (rejects=0)"  expected=100
  [32mPASS[0m  click_calculator: sky 6+7=13 via clicks=True  mac=True
  [32mPASS[0m  type_text: sky='HELLO_FROM_SKY'(rej=False)  mac='HELLO_FROM_MAC'(rej=False)
  [32mPASS[0m  set_value: sky='SET_BY_SKY'  mac='SET_BY_MAC'
  [32mPASS[0m  perform_secondary_action: sky accepted=True ({'text': 'App=com.apple.calculator (pid 20926)\nWindow: "Calculator", App: Calcu)  mac accepted=True ({'text': 'ok'})
  [32mPASS[0m  drag: sky accepted=True  mac accepted=True

9/9 passed
```

### error contract (4)

```
case                                   sky    mac   
──────────────────────────────────────────────────────────
get_app_state('com.fake.does-not-exist OK     OK      needle='not ?found'
click('99999')                         OK     OK      needle='invalid element|no longer valid'
set_value('0')                         OK     OK      needle='not settable'
scroll('sideways')                     OK     OK      needle='scroll direction'

all error messages match contract
```

### press_key vocab (25)

```
key                sky    mac     notes
───────────────────────────────────────────────────────
Return             OK     OK      
Tab                OK     OK      
BackSpace          OK     OK      
Escape             OK     OK      
Delete             OK     OK      
Left               OK     OK      
Right              OK     OK      
Up                 OK     OK      
Down               OK     OK      
Home               OK     OK      
End                OK     OK      
Page_Up            OK     OK      
Page_Down          OK     OK      
plus               OK     OK      
minus              OK     OK      
period             OK     OK      
KP_0               OK     OK      
KP_5               OK     OK      
KP_9               OK     OK      
F1                 OK     OK      
F5                 OK     OK      
cmd+a              OK     OK      
shift+Tab          OK     OK      
alt+Return         OK     OK      
cmd+shift+z        OK     OK      

sky: 25/25  mac: 25/25
```

### perf bench (4 apps)

```
app               sky min(s)  mac min(s)  sky lines  mac lines
──────────────────────────────────────────────────────────────
Calculator             0.208       0.018         51         45
TextEdit               0.126       0.006         28         18
Finder                 0.679       0.090         97        171
Notes                  0.985       1.653        168        446
```

### input latency (2 ops)

```
[type_text 'X']  — broker call → AX visible
  sky: min=604ms  avg=738ms  max=1215ms  (n=5)
  mac: min=152ms  avg=159ms  max=162ms  (n=5)

[press_key 'z']
  sky: min=613ms  avg=622ms  max=632ms  (n=5)
  mac: min=192ms  avg=201ms  max=206ms  (n=5)
```

### stability (100 calls)

```
[stability: 100 × get_app_state Calculator]
  sky: 100/100 ok in 24.3s  (243.2ms/call)
  mac: 100/100 ok in 1.8s  (18.4ms/call)
```

### concurrency (2 agents)

```
[two-agent concurrent click on Calculator]
  agent 0: idx=16 click=ok
  agent 1: idx=26 click=ok

both agents succeeded
```

### workflow (5-step calc)

```
[workflow: clear → 9 × 9 = → expect 81]
  sky: PASS  tree-has-81=True
  mac: PASS  tree-has-81=True
```

