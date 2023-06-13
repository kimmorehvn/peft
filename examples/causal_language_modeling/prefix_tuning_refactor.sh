#!/bin/bash
export MOREH_VISIBLE_DEVICE="2"
export TOKENIZERS_PARALLELISM="false"
export CUDA_VISIBLE_DEVICES="1"

# Define command-line arguments
model_name_or_path="t5-large"
tokenizer_name_or_path="t5-large"
text_column="sentence"
label_column="text_label"
max_length=128
lr=1e-2
num_epochs=5
batch_size=8

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model_name_or_path)
      model_name_or_path=$2
      shift 2
      ;;
    --tokenizer_name_or_path)
      tokenizer_name_or_path=$2
      shift 2
      ;;
    --text_column)
      text_column=$2
      shift 2
      ;;
    --label_column)
      label_column=$2
      shift 2
      ;;
    --max_length)
      max_length=$2
      shift 2
      ;;
    --lr)
      lr=$2
      shift 2
      ;;
    --num_epochs)
      num_epochs=$2
      shift 2
      ;;
    --batch_size)
      batch_size=$2
      shift 2
      ;;
    *)
      echo "Invalid argument: $1"
      exit 1
      ;;
  esac
done

# Define the Python script
python_script='import os
import argparse
import torch
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM, default_data_collator, get_linear_schedule_with_warmup
from peft import get_peft_model, PrefixTuningConfig, TaskType
from datasets import load_dataset
from torch.utils.data import DataLoader
from tqdm import tqdm

# Set environment variables
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["CUDA_VISIBLE_DEVICES"] = "1"
# Load dataset
dataset = load_dataset("financial_phrasebank", "sentences_allagree")
dataset = dataset["train"].train_test_split(test_size=0.1)
dataset["validation"] = dataset["test"]
del dataset["test"]

# Preprocess dataset
classes = dataset["train"].features["label"].names
dataset = dataset.map(
    lambda x: {"text_label": [classes[label] for label in x["label"]]},
    batched=True,
    num_proc=1,
)

# Load tokenizer
tokenizer = AutoTokenizer.from_pretrained("'"$tokenizer_name_or_path"'")

# Define preprocess function
def preprocess_function(examples):
    inputs = examples["'"$text_column"'"]
    targets = examples["'"$label_column"'"]
    model_inputs = tokenizer(inputs, max_length='"$max_length"', padding="max_length", truncation=True, return_tensors="pt")
    labels = tokenizer(targets, max_length=2, padding="max_length", truncation=True, return_tensors="pt")
    labels = labels["input_ids"]
    labels[labels == tokenizer.pad_token_id] = -100
    model_inputs["labels"] = labels
    return model_inputs

# Preprocess datasets
processed_datasets = dataset.map(
    preprocess_function,
    batched=True,
    num_proc=1,
    remove_columns=dataset["train"].column_names,
    load_from_cache_file=False,
    desc="Running tokenizer on dataset",
)
train_dataset = processed_datasets["train"]
eval_dataset = processed_datasets["validation"]

# Create data loaders
train_dataloader = DataLoader(
    train_dataset, shuffle=True, collate_fn=default_data_collator, batch_size='"$batch_size"', pin_memory=True
)
eval_dataloader = DataLoader(
    eval_dataset, collate_fn=default_data_collator, batch_size='"$batch_size"', pin_memory=True
)

# Configure Prefix Tuning
peft_config = PrefixTuningConfig(task_type=TaskType.SEQ_2_SEQ_LM, inference_mode=False, num_virtual_tokens=20)

# Load model
model = AutoModelForSeq2SeqLM.from_pretrained("'"$model_name_or_path"'")
model = get_peft_model(model, peft_config)
model.print_trainable_parameters()
model = model.to("cuda")

# Define optimizer and scheduler
optimizer = torch.optim.AdamW(model.parameters(), lr='"$lr"')
lr_scheduler = get_linear_schedule_with_warmup(
    optimizer=optimizer,
    num_warmup_steps=0,
    num_training_steps=(len(train_dataloader) * '"$num_epochs"'),
)

# Training loop
for epoch in range('"$num_epochs"'):
    model.train()
    total_loss = 0
    for step, batch in enumerate(tqdm(train_dataloader)):
        batch = {k: v.to("cuda") for k, v in batch.items()}
        outputs = model(**batch)
        loss = outputs.loss
        total_loss += loss.detach().float()
        loss.backward()
        optimizer.step()
        lr_scheduler.step()
        optimizer.zero_grad()

    model.eval()
    eval_loss = 0
    eval_preds = []
    for step, batch in enumerate(tqdm(eval_dataloader)):
        batch = {k: v.to("cuda") for k, v in batch.items()}
        with torch.no_grad():
            outputs = model(**batch)
        loss = outputs.loss
        eval_loss += loss.detach().float()
        eval_preds.extend(
            tokenizer.batch_decode(torch.argmax(outputs.logits, -1).detach().cpu().numpy(), skip_special_tokens=True)
        )

    eval_epoch_loss = eval_loss / len(eval_dataloader)
    eval_ppl = torch.exp(eval_epoch_loss)
    train_epoch_loss = total_loss / len(train_dataloader)
    train_ppl = torch.exp(train_epoch_loss)
    print(f"epoch={epoch}: train_ppl={train_ppl} train_epoch_loss={train_epoch_loss} eval_ppl={eval_ppl} eval_epoch_loss={eval_epoch_loss}")

# Calculate accuracy
correct = 0
total = 0
for pred, true in zip(eval_preds, dataset["validation"]["text_label"]):
    if pred.strip() == true.strip():
        correct += 1
    total += 1
accuracy = correct / total * 100
print(f"accuracy={accuracy}% on the evaluation dataset")
print(f"eval_preds[:10]={eval_preds[:10]}")
print(f"dataset['validation']['text_label'][:10]={dataset['validation']['text_label'][:10]}")
'

# Execute the Python script
python -c "$python_script"
