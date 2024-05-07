import pandas as pd
from ydata_profiling import ProfileReport

df = pd.read_csv('IT_Incidents.csv')
profile = ProfileReport(df, title="Ticket Report")
profile.to_file("report.html")