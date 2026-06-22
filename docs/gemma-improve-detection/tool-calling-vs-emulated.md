# Tool calling vs emulated tool use

The emulated Gemma result falls short because it is not real tool calling. It is text
generation pretending to be tool calling.

Native `litert_lm` function calling gives the model a structured tool schema and routes
tool calls through the runtime. Emulated tool calling asks the model to write JSON text,
then the Python script tries to parse that text and decide whether to run the search.

That difference matters.

## What failed in the emulated run

| issue | effect |
| --- | --- |
| Parser brittleness | If Gemma emits prose, malformed JSON, markdown fences, wrong keys, partial JSON, or extra text, the parser can fail. |
| Tool never runs | Once parsing fails, `search_similar_features` is never called, so the true species cannot appear in candidates. |
| Loop drift | The emulated loop is just repeated prompting. Gemma can hedge, repeat itself, answer early, or stop without a valid tool call. |
| Format compliance becomes part of the score | The measured result mixes visual ability, tool-use ability, JSON-format compliance, and parser robustness. |

The native run removes most of that failure mode:

| run | species top-1 | no-final stalls |
| --- | --: | --: |
| emulated | 17.2% | 28.3% (94 / 332) |
| native | 37.7% | 0.9% (3 / 332) |

The clearest example is Lizard: emulated looked weak, while native reached 100% species
accuracy. That says the model capability was there; the emulated control flow was the
problem.

## What happens without tool-call knowledge

If a model does not have tool-call knowledge or function-calling training, the result can
be as bad as the emulated run, and often worse.

Tool calling is not just "write JSON". The model has to learn:

- when to call a tool
- which tool to call
- how to fill arguments
- how to obey the exact schema
- how to continue after the tool result
- when to stop and produce the final answer

Expected reliability:

```text
native tool-trained model > emulated tool-trained model > non-tool-trained model prompted to imitate tools
```

## External evidence

| source | relevant point |
| --- | --- |
| [Toolformer](https://arxiv.org/abs/2302.04761) | Tool use improves when models are trained to decide when to call APIs, what arguments to pass, and how to use results. Generic prompting alone is weaker. |
| [Hammer](https://arxiv.org/abs/2410.04587) | On-device function calling needs dedicated tuning and function masking. Tool-calling performance varies a lot and models can be misled by function names or schemas. |
| [IFEval-FC](https://arxiv.org/abs/2509.18420) | Even strong modern models often fail precise function-call formatting rules embedded in schemas. Weaker or non-tool-trained models will be brittle. |
| [LongFuncEval](https://arxiv.org/abs/2505.10570) | Function-calling performance degrades with many tools, long tool outputs, and multi-turn conversations. Our pipeline has multi-turn tool use and long candidate outputs. |

## How to make emulated closer to native

The main target is simple:

```text
current emulated:
  malformed tool call -> no search -> stall/failure

improved emulated:
  malformed tool call -> repair/normalize/extract -> search still runs
```

Recommended fixes:

| fix | why it helps |
| --- | --- |
| Use constrained decoding if available | Forces JSON/object output instead of relying on polite prompting. |
| Make the parser tolerant | Handles markdown fences, prose around JSON, trailing commas, partial object extraction, wrong casing, and alternate key names. |
| Accept multiple tool-call shapes | Normalize `tool` / `name` / `function` and `arguments` / `args` / `parameters`. |
| Add one format-repair turn | If parsing fails, ask only for valid tool-call JSON, not new reasoning. |
| Fallback to trait extraction | If repair fails, extract visual traits from prose and call search anyway. |
| Never let one bad parse become a stall | A rough search call is better than no search call. |
| Mimic native tool-call tokens when available | Gemma LiteRT exposes tool-call markers such as `<|tool_call>`, `<tool_call|>`, `<|tool_response>`, and `<tool_response|>`. Emulated prompting should use the format the model expects. |

## Better design for non-tool-trained models

For a model that does not understand tools, do not ask it to "call a tool". Split the
pipeline so the model only does simpler tasks:

```text
image -> model outputs visual traits JSON
traits -> app runs DB search deterministically
candidates -> model chooses best species
final -> app validates JSON
```

This removes the need for the model to understand the tool-calling protocol. It only has
to describe the image and choose from candidates.

Recommended non-tool model flow:

1. Ask for visual traits only, in a small JSON schema.
2. Run `search_similar_features` in app code.
3. Send compact candidates back to the model.
4. Ask the model to choose the best candidate.
5. Use constrained JSON or repair parsing for the final answer.

This should be more robust than emulated function calling because the control flow stays
in code, not in model-generated protocol text.
