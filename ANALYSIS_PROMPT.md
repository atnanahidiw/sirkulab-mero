# Analysis Prompt Engineering

## System Instruction

The app uses the following system instruction for the Gemma 4 model:

```
You are an expert wildlife biologist and conservationist specializing in endangered species identification.
Your task is to analyze images and identify if they contain endangered species.

For each image:
1. Identify the species if possible (common name and scientific name)
2. Determine if it's endangered, threatened, or of least concern
3. Provide conservation status (IUCN Red List category if known)
4. Share interesting facts about the species
5. Suggest conservation actions if endangered

Be concise but informative. If the image doesn't contain an animal or plant, say so.
If you're unsure, admit uncertainty but provide best guess with confidence level.

Format your response with clear sections.
```

## User Prompt

After sending the image, the app adds this text prompt:

```
Analyze this image for endangered species. Identify the species, conservation status, and provide relevant information.
```

## Expected Response Format

The model should respond with structured information:

```
# Species Identification

**Common Name:** [Species common name]
**Scientific Name:** [Genus species]
**Confidence:** [High/Medium/Low]

# Conservation Status

**IUCN Red List:** [Category, e.g., Endangered, Vulnerable, Least Concern]
**Population Trend:** [Increasing/Decreasing/Stable]
**Threats:** [Main threats to the species]

# Species Information

[Interesting facts about the species, habitat, behavior, etc.]

# Conservation Recommendations

[Actions that can help protect this species]
```

## Example Analysis

For a photo of a tiger:

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

The Bengal tiger is the most numerous tiger subspecies, found primarily in India. 
They are solitary predators that require large territories. An adult male can weigh 
up to 260 kg (570 lb) and measure up to 3.1 meters (10 ft) in length.

# Conservation Recommendations

1. Support anti-poaching patrols and wildlife corridors
2. Promote sustainable tourism that benefits local communities
3. Support habitat restoration projects
4. Report illegal wildlife trade
```

## Improving Accuracy

To improve identification accuracy:

1. **Clear Images**: Well-lit, focused photos work best
2. **Multiple Angles**: If possible, provide different views
3. **Context Information**: Location, habitat type (optional)
4. **Size Reference**: Include scale if possible

## Limitations

1. **Model Knowledge**: Gemma 4's knowledge cutoff is [date]
2. **Regional Species**: May not recognize locally endangered species
3. **Similar Species**: May confuse visually similar species
4. **Juvenile Forms**: Young animals may be harder to identify

## Customization

The prompt can be customized for:

1. **Regional Focus**: Add "Focus on Southeast Asian species"
2. **Taxonomic Group**: "Specialize in bird identification"
3. **Conservation Level**: "Only report if critically endangered"
4. **Output Format**: Request JSON or specific sections

## Testing Prompts

Test with known endangered species:
- Giant Panda (Ailuropoda melanoleuca)
- Mountain Gorilla (Gorilla beringei beringei)
- Black Rhino (Diceros bicornis)
- Hawksbill Turtle (Eretmochelys imbricata)
- Philippine Eagle (Pithecophaga jefferyi)