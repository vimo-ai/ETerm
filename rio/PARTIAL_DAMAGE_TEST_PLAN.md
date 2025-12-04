# Partial Damage Rendering - Test Plan

## Test Environment Setup

### Prerequisites:
- Build completed successfully (✅ verified)
- Running on macOS (partial damage only works on macOS)
- Terminal emulator running

### Expected Console Output:
The rendering system will print performance logs like:
```
🎨 [Sugarloaf Render - Off-screen] Damage: Partial (3)
   Total chars: 1234
   Total lines rendered: 3
   💾 Layout cache: 120 hits, 3 misses (hit rate: 97.5%)
   🔤 Font cache: 45 fonts cached
   ⏱️  Render time: 1500μs (1ms)
```

## Test Scenarios

### Test 1: Typing (Expected: Partial Damage)
**Procedure**:
1. Open terminal
2. Type characters slowly (e.g., "hello world")
3. Observe console logs

**Expected Results**:
- Damage type: `Partial`
- Damaged lines: 1-2 (current line + possibly status line)
- Render time: 1-3ms
- Layout cache hit rate: >95%

**Success Criteria**:
- ✅ Damage is reported as "Partial"
- ✅ Total lines rendered < total terminal lines
- ✅ Render time < 3ms

### Test 2: Cursor Movement (Expected: Partial Damage)
**Procedure**:
1. Type some text
2. Use arrow keys to move cursor
3. Observe console logs

**Expected Results**:
- Damage type: `Partial`
- Damaged lines: 1-2 (old cursor line + new cursor line)
- Render time: 1-2ms
- Layout cache hit rate: ~100% (no content change)

**Success Criteria**:
- ✅ Damage is reported as "Partial"
- ✅ Only 1-2 lines rendered
- ✅ Render time < 2ms

### Test 3: Vertical Scrolling (Expected: Full Damage)
**Procedure**:
1. Fill terminal with text (e.g., `ls -la /usr/bin`)
2. Use Page Up/Down or scroll
3. Observe console logs

**Expected Results**:
- Damage type: `Full`
- All lines rendered
- Render time: 5-10ms

**Success Criteria**:
- ✅ Damage is reported as "Full"
- ✅ All lines rendered
- ✅ Render time similar to before (~7ms)

### Test 4: Window Resize (Expected: Full Damage)
**Procedure**:
1. Resize terminal window
2. Observe console logs

**Expected Results**:
- Damage type: `Full`
- All lines rendered
- Render time: 5-10ms

**Success Criteria**:
- ✅ Damage is reported as "Full"
- ✅ Off-screen surface recreated
- ✅ Content renders correctly

### Test 5: Fast Typing (Stress Test)
**Procedure**:
1. Hold down a key to generate continuous input
2. Observe console logs
3. Check for visual artifacts

**Expected Results**:
- Damage type: `Partial`
- Damaged lines: 1-2 per frame
- No visual glitches
- Smooth rendering

**Success Criteria**:
- ✅ Damage is consistently "Partial"
- ✅ No visual artifacts (ghosting, missing characters)
- ✅ Render time stays low (<3ms)

### Test 6: Multi-Line Edit (Expected: Partial Damage)
**Procedure**:
1. Open vim or nano
2. Edit text across multiple lines
3. Observe console logs

**Expected Results**:
- Damage type: `Partial` (unless scrolling)
- Damaged lines: 2-10 (depending on operation)
- Render time: 2-5ms

**Success Criteria**:
- ✅ Damage is "Partial" for most operations
- ✅ Lines rendered matches actual changed lines
- ✅ Visual correctness maintained

### Test 7: Background Color Changes (Expected: Partial Damage)
**Procedure**:
1. Run command with colored output (e.g., `ls --color`)
2. Observe console logs

**Expected Results**:
- Damage type: `Partial`
- Only output lines damaged
- Render time: 1-3ms per line

**Success Criteria**:
- ✅ Colors render correctly
- ✅ Only changed lines damaged
- ✅ Background cleared properly for damaged lines

## Performance Benchmarks

### Baseline (Full Damage):
- Typing: ~7ms per frame
- All lines rendered: ~50 lines

### Target (Partial Damage):
- Typing: ~1-2ms per frame (70-85% improvement)
- Lines rendered: 1-2 lines

### Measurement Points:
1. Average render time for 100 typing events
2. Peak render time during typing
3. Cache hit rate during typing
4. Visual quality (no artifacts)

## Debug Checklist

If partial damage doesn't work as expected:

### Check 1: Damage Information
- [ ] `sugarloaf_set_damage` is called before `sugarloaf_flush_and_render`
- [ ] Damage array is correctly populated
- [ ] `has_full_damage` flag is set correctly

### Check 2: Off-Screen Buffer
- [ ] Off-screen surface is created successfully
- [ ] Surface size matches window size
- [ ] Surface persists between frames

### Check 3: Rendering Logic
- [ ] Damaged lines are cleared correctly
- [ ] Only damaged lines are rendered
- [ ] Unchanged lines are preserved in buffer

### Check 4: Terminal State
- [ ] `terminal.damage()` returns correct damage info
- [ ] `reset_damage()` is called after each frame
- [ ] Lock contention is minimal

## Known Limitations

1. **Multi-Terminal**: Currently treats any Full damage from one terminal as Full damage for all
2. **Y-Offset**: Assumes single terminal at Y=0; multi-terminal needs per-terminal offset
3. **Async Updates**: Background updates may trigger Full damage unnecessarily

## Success Metrics

### Primary:
- ✅ Partial damage works for typing (1-2ms render time)
- ✅ Full damage still works for scroll/resize (5-10ms)
- ✅ No visual artifacts

### Secondary:
- ✅ Cache hit rate >95% during typing
- ✅ Memory usage stable
- ✅ CPU usage reduced during typing

## Next Steps After Testing

1. If successful:
   - Remove old Full-damage-only code
   - Optimize multi-terminal damage tracking
   - Add GPU-accelerated blitting

2. If issues found:
   - Check debug checklist
   - Add more detailed logging
   - Consider fallback to Full damage

## Test Log Template

```
Date: YYYY-MM-DD
Tester: [Name]
Build: [git commit hash]

Test 1: Typing
- Damage type: [Full/Partial]
- Lines rendered: [X/Y]
- Render time: [Xms]
- Visual quality: [OK/Artifacts]
- Notes: [Any observations]

Test 2: Cursor Movement
- Damage type: [Full/Partial]
- Lines rendered: [X/Y]
- Render time: [Xms]
- Visual quality: [OK/Artifacts]
- Notes: [Any observations]

[... continue for all tests ...]

Overall Assessment:
- [ ] Partial damage working correctly
- [ ] Performance improvement achieved
- [ ] No regressions
- [ ] Ready for production
```
