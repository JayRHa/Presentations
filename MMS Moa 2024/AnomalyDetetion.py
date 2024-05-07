import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from sklearn.ensemble import IsolationForest

# Generate random data for IT incidents
def generate_data(num_days=200):
    dates = pd.date_range(start="2023-01-01", periods=num_days)
    categories = ['Network', 'Hardware', 'Software', 'User', 'Security']
    
    data = {
        'Date': dates,
        'Category': np.random.choice(categories, size=num_days),
        'Incidents': np.abs(np.random.normal(loc=50, scale=15, size=num_days)).astype(int)
    }
    return pd.DataFrame(data)

# Detect positive anomalies in incident data
def detect_positive_anomalies(df):
    model = IsolationForest(n_estimators=100, contamination=0.05)
    df['Scores'] = model.fit(df[['Incidents']]).decision_function(df[['Incidents']])
    df['Anomaly'] = df['Scores'] < -0.1 
    anomalies = df[df['Anomaly'] == True]
    return anomalies

# Generate data and detect anomalies
df = generate_data()
anomalies = detect_positive_anomalies(df)

# Plotting
plt.figure(figsize=(10, 6))
plt.plot(df['Date'], df['Incidents'], label='Incidents')
plt.scatter(anomalies['Date'], anomalies['Incidents'], color='red', label='Anomaly')
plt.title('IT Incidents Over Time with Positive Anomalies Highlighted')
plt.xlabel('Date')
plt.ylabel('Number of Incidents')
plt.legend()
plt.show()
