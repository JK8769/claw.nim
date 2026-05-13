"""
储能系统电力市场交易优化 - 完整优化版
================================================
优化思路：
1. 增强特征工程：周期编码、预测偏差、滞后特征、滚动统计、供需比
2. 多模型集成：HistGradientBoosting + GradientBoosting + RandomForest
3. 暴力搜索最优充放电策略（遍历所有合法 tc, td 组合）
4. 策略鲁棒性：考虑预测误差，加入安全边际
"""
import pandas as pd
import numpy as np
from sklearn.ensemble import (
    HistGradientBoostingRegressor,
    GradientBoostingRegressor,
    RandomForestRegressor,
    ExtraTreesRegressor,
)
from sklearn.metrics import mean_squared_error, mean_absolute_error
import warnings
warnings.filterwarnings('ignore')

# ==================== 路径配置 ====================
BASE_DIR = r'c:/Users/jiusi/Desktop/energy'
train_feature_path = f'{BASE_DIR}/to_sais_new/train/mengxi_boundary_anon_filtered.csv'
train_label_path = f'{BASE_DIR}/to_sais_new/train/mengxi_node_price_selected.csv'
test_feature_path = f'{BASE_DIR}/to_sais_new/test/test_in_feature_ori.csv'
output_price_path = f'{BASE_DIR}/output_price.csv'
output_power_path = f'{BASE_DIR}/output_power.csv'

# 边界条件基础特征列
base_feature_cols = [
    '系统负荷预测值', '风光总加预测值', '联络线预测值',
    '风电预测值', '光伏预测值', '水电预测值', '非市场化机组预测值'
]
target_col = 'A'

# ==================== 储能系统参数 ====================
ENERGY_CAPACITY = 8000       # 储能容量
CHARGE_POWER = -1000         # 充电功率
DISCHARGE_POWER = 1000       # 放电功率
DURATION = 8                 # 单次充放电持续时间（8个15分钟 = 2小时）
POINTS_PER_DAY = 96          # 每天96个时间点


# ==================== 1. 数据准备 ====================
print("=" * 60)
print("步骤1: 数据加载")
print("=" * 60)

df_feat = pd.read_csv(train_feature_path)
df_label = pd.read_csv(train_label_path)
df_test = pd.read_csv(test_feature_path)

# 训练集：内连接对齐
df_train = pd.merge(df_feat, df_label, on='times', how='inner')
df_train['times'] = pd.to_datetime(df_train['times'])
df_test['times'] = pd.to_datetime(df_test['times'])

print(f"训练集: {len(df_train)} 条记录")
print(f"测试集: {len(df_test)} 条记录")
print(f"训练时间范围: {df_train['times'].iloc[0]} ~ {df_train['times'].iloc[-1]}")
print(f"测试时间范围: {df_test['times'].iloc[0]} ~ {df_test['times'].iloc[-1]}")


# ==================== 2. 增强特征工程 ====================
def add_advanced_features(df, is_train=True):
    df = df.copy()

    # --- 基础时间特征 ---
    df['hour'] = df['times'].dt.hour
    df['minute'] = df['times'].dt.minute
    df['dayofweek'] = df['times'].dt.dayofweek
    df['month'] = df['times'].dt.month
    df['dayofyear'] = df['times'].dt.dayofyear
    df['minute_of_day'] = df['hour'] * 60 + df['minute']

    # --- 周期性编码 ---
    df['hour_sin'] = np.sin(2 * np.pi * df['hour'] / 24)
    df['hour_cos'] = np.cos(2 * np.pi * df['hour'] / 24)
    df['minute_sin'] = np.sin(2 * np.pi * df['minute_of_day'] / 1440)
    df['minute_cos'] = np.cos(2 * np.pi * df['minute_of_day'] / 1440)
    df['dow_sin'] = np.sin(2 * np.pi * df['dayofweek'] / 7)
    df['dow_cos'] = np.cos(2 * np.pi * df['dayofweek'] / 7)

    # --- 关键时段标记 ---
    df['is_morning_peak'] = ((df['hour'] >= 7) & (df['hour'] < 11)).astype(int)
    df['is_evening_peak'] = ((df['hour'] >= 17) & (df['hour'] < 21)).astype(int)
    df['is_valley'] = (df['hour'] < 6).astype(int)
    df['is_weekend'] = (df['dayofweek'] >= 5).astype(int)

    # --- 预测偏差特征 ---
    if is_train:
        for feat in ['系统负荷', '风光总加', '联络线', '风电', '光伏', '水电', '非市场化机组']:
            actual_col = f'{feat}实际值'
            pred_col = f'{feat}预测值'
            if actual_col in df.columns and pred_col in df.columns:
                df[f'{feat}_pred_err'] = df[actual_col] - df[pred_col]
                df[f'{feat}_pred_err_ratio'] = df[f'{feat}_pred_err'] / (df[pred_col].abs() + 1e-6)
    else:
        for feat in ['系统负荷', '风光总加', '联络线', '风电', '光伏', '水电', '非市场化机组']:
            df[f'{feat}_pred_err'] = 0.0
            df[f'{feat}_pred_err_ratio'] = 0.0

    # --- 滞后特征 ---
    lag_features = ['A'] if 'A' in df.columns else []
    lag_features += ['系统负荷预测值', '风光总加预测值']
    for col in lag_features:
        for lag in [1, 4, 8, 16, 96]:
            if col in df.columns:
                df[f'{col}_lag_{lag}'] = df[col].shift(lag)

    # --- 滚动统计特征 ---
    if 'A' in df.columns:
        for window in [8, 16, 48, 96]:
            df[f'price_mean_{window}'] = df['A'].rolling(window=window, min_periods=1).mean()
            df[f'price_std_{window}'] = df['A'].rolling(window=window, min_periods=1).std().fillna(0)
            df[f'price_min_{window}'] = df['A'].rolling(window=window, min_periods=1).min()
            df[f'price_max_{window}'] = df['A'].rolling(window=window, min_periods=1).max()
    else:
        for window in [8, 16, 48, 96]:
            df[f'price_mean_{window}'] = np.nan
            df[f'price_std_{window}'] = np.nan
            df[f'price_min_{window}'] = np.nan
            df[f'price_max_{window}'] = np.nan

    # --- 供需比特征 ---
    df['total_supply'] = df['风光总加预测值'] + df['水电预测值'] + df['非市场化机组预测值']
    df['supply_demand_ratio'] = df['total_supply'] / (df['系统负荷预测值'].abs() + 1e-6)
    df['net_load'] = df['系统负荷预测值'] - df['风光总加预测值']

    # --- 风光占比 ---
    df['renewable_ratio'] = df['风光总加预测值'] / (df['系统负荷预测值'].abs() + 1e-6)
    df['wind_ratio'] = df['风电预测值'] / (df['系统负荷预测值'].abs() + 1e-6)
    df['solar_ratio'] = df['光伏预测值'] / (df['系统负荷预测值'].abs() + 1e-6)

    # --- 交叉特征 ---
    df['load_x_wind'] = df['系统负荷预测值'] * df['风电预测值']
    df['load_x_solar'] = df['系统负荷预测值'] * df['光伏预测值']
    df['wind_diff_solar'] = df['风电预测值'] - df['光伏预测值']

    # --- 价格变化率 ---
    if 'A' in df.columns:
        df['price_diff_1'] = df['A'].diff(1).fillna(0)
        df['price_diff_4'] = df['A'].diff(4).fillna(0)
        df['price_pct_1'] = df['A'].pct_change(1).fillna(0)
    else:
        df['price_diff_1'] = np.nan
        df['price_diff_4'] = np.nan
        df['price_pct_1'] = np.nan

    return df


print("\n" + "=" * 60)
print("步骤2: 特征工程")
print("=" * 60)

df_train = add_advanced_features(df_train, is_train=True)
df_test = add_advanced_features(df_test, is_train=False)

# 确定最终特征列（排除时间、目标、实际值列）
exclude_cols = {'times', target_col, 'date'}
for col in df_train.columns:
    if '实际值' in col:
        exclude_cols.add(col)

all_features = [col for col in df_train.columns if col not in exclude_cols]
print(f"特征数量: {len(all_features)}")

# 处理NaN
df_train[all_features] = df_train[all_features].ffill().fillna(0)

X = df_train[all_features].values
y = df_train[target_col].values


# ==================== 3. 模型训练（多模型集成）====================
print("\n" + "=" * 60)
print("步骤3: 模型训练")
print("=" * 60)

# 时序划分：最后20%验证
split_idx = int(len(X) * 0.8)
X_train, X_val = X[:split_idx], X[split_idx:]
y_train, y_val = y[:split_idx], y[split_idx:]

# ---------- 3.1 HistGradientBoosting（sklearn内置，类似LightGBM）----------
print("\n--- HistGradientBoosting ---")
hgb_model = HistGradientBoostingRegressor(
    max_iter=2000,
    learning_rate=0.03,
    max_depth=8,
    min_samples_leaf=20,
    l2_regularization=1.0,
    max_bins=255,
    random_state=42,
    early_stopping=True,
    validation_fraction=0.1,
    n_iter_no_change=100,
)
hgb_model.fit(X_train, y_train)

# ---------- 3.2 GradientBoosting ----------
print("--- GradientBoosting ---")
gb_model = GradientBoostingRegressor(
    n_estimators=800,
    learning_rate=0.03,
    max_depth=6,
    min_samples_leaf=20,
    subsample=0.8,
    max_features=0.8,
    random_state=42,
    validation_fraction=0.1,
    n_iter_no_change=50,
)
gb_model.fit(X_train, y_train)

# ---------- 3.3 RandomForest ----------
print("--- RandomForest ---")
rf_model = RandomForestRegressor(
    n_estimators=500,
    max_depth=12,
    min_samples_leaf=10,
    max_features=0.7,
    random_state=42,
    n_jobs=-1,
)
rf_model.fit(X_train, y_train)

# ---------- 3.4 ExtraTrees ----------
print("--- ExtraTrees ---")
et_model = ExtraTreesRegressor(
    n_estimators=500,
    max_depth=12,
    min_samples_leaf=10,
    max_features=0.7,
    random_state=42,
    n_jobs=-1,
)
et_model.fit(X_train, y_train)

# ---------- 3.5 模型融合验证 ----------
print("\n--- 模型融合验证 ---")
hgb_val_pred = hgb_model.predict(X_val)
gb_val_pred = gb_model.predict(X_val)
rf_val_pred = rf_model.predict(X_val)
et_val_pred = et_model.predict(X_val)

# 加权平均融合
w_hgb, w_gb, w_rf, w_et = 0.4, 0.25, 0.2, 0.15
val_ensemble = w_hgb * hgb_val_pred + w_gb * gb_val_pred + w_rf * rf_val_pred + w_et * et_val_pred

for name, pred in [('HistGB', hgb_val_pred), ('GB', gb_val_pred),
                    ('RF', rf_val_pred), ('ET', et_val_pred),
                    ('Ensemble', val_ensemble)]:
    rmse = np.sqrt(mean_squared_error(y_val, pred))
    mae = mean_absolute_error(y_val, pred)
    print(f"  {name:12s}: RMSE={rmse:.6f}, MAE={mae:.6f}")

# 特征重要性
print("\n--- Top 20 重要特征 ---")
importance = hgb_model.feature_importances_
feat_imp = sorted(zip(all_features, importance), key=lambda x: -x[1])
for i, (feat, imp) in enumerate(feat_imp[:20]):
    print(f"  {i+1:2d}. {feat:30s}: {imp:.4f}")


# ==================== 4. 测试集推理 ====================
print("\n" + "=" * 60)
print("步骤4: 测试集推理")
print("=" * 60)

df_test[all_features] = df_test[all_features].ffill().fillna(0)
X_test = df_test[all_features].values

hgb_test_pred = hgb_model.predict(X_test)
gb_test_pred = gb_model.predict(X_test)
rf_test_pred = rf_model.predict(X_test)
et_test_pred = et_model.predict(X_test)

y_test_pred = w_hgb * hgb_test_pred + w_gb * gb_test_pred + w_rf * rf_test_pred + w_et * et_test_pred

df_price = pd.DataFrame({'times': df_test['times'], '实时价格': y_test_pred})
df_price.to_csv(output_price_path, index=False)
print(f"电价预测已保存: {output_price_path}")
print(f"预测价格范围: [{y_test_pred.min():.4f}, {y_test_pred.max():.4f}], "
      f"均值={y_test_pred.mean():.4f}")


# ==================== 5. 充放电策略生成（核心）====================
def compute_prefix_sum(prices):
    n = len(prices)
    prefix = np.zeros(n + 1)
    prefix[1:] = np.cumsum(prices)
    return prefix


def get_sum(prefix, start, end):
    return prefix[end] - prefix[start]


def generate_optimal_strategy(predicted_prices):
    """
    暴力搜索最优充放电策略。
    约束：充电8个点，放电8个点，先充后放，0<=tc<=80, tc+8<=td<=88
    """
    n = len(predicted_prices)
    prefix = compute_prefix_sum(predicted_prices)

    best_profit = 0
    best_tc = None
    best_td = None

    for tc in range(0, 81):
        for td in range(tc + DURATION, 89):
            charge_sum = get_sum(prefix, tc, tc + DURATION)
            discharge_sum = get_sum(prefix, td, td + DURATION)
            profit = DISCHARGE_POWER * discharge_sum + CHARGE_POWER * charge_sum

            if profit > best_profit:
                best_profit = profit
                best_tc = tc
                best_td = td

    power = np.zeros(n, dtype=float)
    if best_tc is not None and best_profit > 0:
        power[best_tc:best_tc + DURATION] = CHARGE_POWER
        power[best_td:best_td + DURATION] = DISCHARGE_POWER

    return power, best_profit, best_tc, best_td


def generate_strategy_with_margin(predicted_prices, margin_ratio=0.02):
    """带安全边际的策略：价差比例不足时放弃操作"""
    power, profit, tc, td = generate_optimal_strategy(predicted_prices)

    if tc is not None and margin_ratio > 0:
        charge_avg = np.mean(predicted_prices[tc:tc + DURATION])
        discharge_avg = np.mean(predicted_prices[td:td + DURATION])
        spread_ratio = (discharge_avg - charge_avg) / (charge_avg + 1e-6)

        if spread_ratio < margin_ratio:
            power = np.zeros(len(predicted_prices), dtype=float)
            profit = 0
            tc = None
            td = None

    return power, profit, tc, td


# ==================== 6. 执行策略生成 ====================
print("\n" + "=" * 60)
print("步骤5: 充放电策略优化")
print("=" * 60)

df_test['date'] = df_test['times'].dt.date
dates = sorted(df_test['date'].unique())
print(f"测试集天数: {len(dates)}")

results = []
total_profit = 0
trade_days = 0

for date in dates:
    mask = df_test['date'] == date
    day_data = df_test[mask].copy()
    day_prices = day_data['实时价格'].values

    if len(day_prices) != POINTS_PER_DAY:
        print(f"  警告: {date} 有 {len(day_prices)} 个点，跳过")
        for _, row in day_data.iterrows():
            results.append({'times': row['times'], '实时价格': row['实时价格'], 'power': 0.0})
        continue

    power, profit, tc, td = generate_strategy_with_margin(day_prices, margin_ratio=0.02)

    if tc is not None:
        charge_avg = np.mean(day_prices[tc:tc + DURATION])
        discharge_avg = np.mean(day_prices[td:td + DURATION])
        trade_days += 1
        print(f"  {date}: 充电t={tc:2d}({tc*15//60:02d}:{(tc*15)%60:02d}, 均价={charge_avg:.4f}) "
              f"-> 放电t={td:2d}({td*15//60:02d}:{(td*15)%60:02d}, 均价={discharge_avg:.4f}) "
              f"| 收益={profit:.2f}")
    else:
        print(f"  {date}: 不操作 (价差不足)")

    total_profit += profit

    for i, (_, row) in enumerate(day_data.iterrows()):
        results.append({
            'times': row['times'],
            '实时价格': row['实时价格'],
            'power': power[i]
        })

df_output = pd.DataFrame(results)
df_output.to_csv(output_power_path, index=False)

print(f"\n{'=' * 60}")
print(f"策略统计:")
print(f"  总天数: {len(dates)}")
print(f"  交易天数: {trade_days}")
print(f"  总收益: {total_profit:.2f}")
print(f"  日均收益: {total_profit / len(dates):.2f}")
print(f"输出已保存: {output_power_path}")
print(f"{'=' * 60}")
