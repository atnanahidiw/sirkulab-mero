# Testing Picture That App

## Test Cases

### 1. Model Download and Installation
**Scenario**: First-time app launch
**Steps**:
1. Launch app
2. Check model status shows "Model not installed"
3. Tap "Download Model (2.4GB)"
4. Monitor download progress
5. Verify model loads successfully

**Expected Results**:
- Download progress shows percentage
- Model status changes to "Model ready"
- No errors during download/installation

### 2. Camera Capture
**Scenario**: Take photo with camera
**Steps**:
1. Ensure model is loaded
2. Tap "Camera" button
3. Grant camera permission if prompted
4. Take photo of test subject
5. Confirm photo appears in preview

**Expected Results**:
- Camera opens successfully
- Photo captured and displayed
- No permission errors

### 3. Gallery Selection
**Scenario**: Select photo from gallery
**Steps**:
1. Ensure model is loaded
2. Tap "Gallery" button
3. Grant photo library permission
4. Select test image
5. Confirm image appears in preview

**Expected Results**:
- Gallery opens successfully
- Image selected and displayed
- No permission errors

### 4. Species Identification
**Scenario**: Analyze known endangered species
**Test Images**:
- Bengal tiger (Panthera tigris tigris)
- Giant panda (Ailuropoda melanoleuca)
- Mountain gorilla (Gorilla beringei beringei)
- Hawksbill turtle (Eretmochelys imbricata)

**Steps**:
1. Select/upload test image
2. Tap "Identify Endangered Species"
3. Wait for analysis
4. Review results

**Expected Results**:
- Analysis completes within reasonable time
- Species correctly identified (or close)
- Conservation status provided
- Informative details shown

### 5. Non-Endangered Species
**Scenario**: Analyze common species
**Test Images**:
- Domestic cat (Felis catus)
- House sparrow (Passer domesticus)
- Common daisy (Bellis perennis)

**Steps**:
1. Select/upload test image
2. Tap "Identify Endangered Species"
3. Wait for analysis

**Expected Results**:
- Analysis completes
- Species identified as not endangered
- Appropriate message shown

### 6. Non-Animal Images
**Scenario**: Analyze non-biological images
**Test Images**:
- Landscape photo
- Building photo
- Object photo (car, furniture)

**Steps**:
1. Select/upload test image
2. Tap "Identify Endangered Species"
3. Wait for analysis

**Expected Results**:
- Analysis completes
- Message indicates no animal/plant detected
- Appropriate response format

### 7. Offline Functionality
**Scenario**: Use app without internet
**Steps**:
1. Download model with internet
2. Enable airplane mode
3. Restart app
4. Analyze test images

**Expected Results**:
- App works without internet
- Model loads from local storage
- Analysis functions normally

### 8. Performance Testing
**Scenario**: Measure performance metrics
**Steps**:
1. Time model loading
2. Time image analysis
3. Monitor memory usage
4. Check battery impact

**Expected Results**:
- Model loads within 30 seconds
- Analysis completes within 60 seconds
- Memory usage stays within limits
- Battery drain acceptable

### 9. Error Handling
**Scenario**: Test error conditions
**Test Cases**:
- No camera permission
- No storage permission
- Corrupted model file
- Insufficient storage
- Network errors during download

**Expected Results**:
- Clear error messages
- Graceful degradation
- Recovery options provided

## Test Data

### Sample Images for Testing

Download test images from:
1. **Endangered species**: [ARKive](https://www.arkive.org/) or [IUCN Red List](https://www.iucnredlist.org/)
2. **Common species**: Wikimedia Commons
3. **Test datasets**: [iNaturalist](https://www.inaturalist.org/)

### Expected Output Examples

#### Bengal Tiger Analysis
```
# Species Identification

**Common Name:** Bengal Tiger
**Scientific Name:** Panthera tigris tigris
**Confidence:** High

# Conservation Status

**IUCN Red List:** Endangered
**Population Trend:** Decreasing
**Threats:** Habitat loss, poaching, human-wildlife conflict

# Species Information

The Bengal tiger is found primarily in India with smaller populations in Bangladesh, Nepal, Bhutan, and Myanmar. They are the most numerous tiger subspecies but face significant threats.

# Conservation Recommendations

1. Support protected area management
2. Combat wildlife trafficking
3. Promote human-tiger conflict mitigation
4. Support habitat connectivity projects
```

#### Domestic Cat Analysis
```
# Species Identification

**Common Name:** Domestic Cat
**Scientific Name:** Felis catus
**Confidence:** High

# Conservation Status

**IUCN Red List:** Domesticated (Not evaluated)
**Note:** Domestic cats are not considered wildlife and have no conservation status.

# Species Information

Domestic cats are small carnivorous mammals that have been domesticated for thousands of years. They are found worldwide as companion animals.

# Conservation Impact

Note: Free-ranging domestic cats can impact local wildlife populations through predation.
```

## Automated Testing

### Unit Tests
```bash
flutter test
```

### Integration Tests
```bash
flutter test integration_test/
```

### Golden Tests
```bash
flutter test --update-goldens
```

## Manual Testing Checklist

- [ ] App launches without crashes
- [ ] Model downloads successfully
- [ ] Camera permission handled correctly
- [ ] Gallery permission handled correctly
- [ ] Image selection works
- [ ] Analysis produces results
- [ ] Results display correctly
- [ ] Share functionality works
- [ ] Copy to clipboard works
- [ ] Back navigation works
- [ ] App works offline
- [ ] Memory usage acceptable
- [ ] Battery impact acceptable
- [ ] No memory leaks
- [ ] App resumes correctly
- [ ] Landscape/portrait orientation
- [ ] Different screen sizes
- [ ] Dark/light theme

## Performance Benchmarks

| Device | Model Load Time | Analysis Time | Memory Usage |
|--------|----------------|---------------|--------------|
| iPhone 15 Pro | < 20s | < 30s | < 500MB |
| Samsung S23 | < 25s | < 35s | < 600MB |
| Pixel 7 | < 30s | < 40s | < 550MB |
| Web (Chrome) | < 15s | < 25s | < 400MB |

## Reporting Issues

When reporting issues, include:
1. Device model and OS version
2. App version
3. Steps to reproduce
4. Expected vs actual behavior
5. Screenshots/videos
6. Logs (if available)

## Continuous Integration

Setup CI with:
```yaml
# GitHub Actions example
name: Flutter Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
      - run: flutter pub get
      - run: flutter test
      - run: flutter analyze
```