import pandas as pd
import os
from openai import AzureOpenAI

## Read CSV
df = pd.read_csv('IT_Incidents.csv')
titles = df['Title'].str.cat(sep=';')

prompt = f"""
Create a summary of the current IT issues based on the incident tiles provided in the ## Incident section


## Incidents
{titles}
"""

client = AzureOpenAI(
  azure_endpoint = "https://jrtestbook.openai.azure.com/", 
  api_key='ADD HERE YOU KEY OR SET THE AS ENV',  
  api_version="2024-02-15-preview"
)

message_text = [{"role":"system","content":"You are an AI assistant that helps people find information."},
                {"role":"user","content": prompt},
            ]

completion = client.chat.completions.create(
   model="gpt-4-32k",
  messages = message_text,
  temperature=0.7,
  max_tokens=800,
  top_p=0.95,
  frequency_penalty=0,
  presence_penalty=0,
  stop=None
)

print(completion.choices[0].message.content)