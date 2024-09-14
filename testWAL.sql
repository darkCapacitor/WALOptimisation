WITH NumberSequence AS (
    SELECT TOP (1000) -- Adjust based on your maximum expected iterations
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
    FROM master.dbo.spt_values t1
    CROSS JOIN master.dbo.spt_values t2
),

-- Generate all potential repayment dates
RepaymentDates AS (
    SELECT 
        N,
        DATEADD(MONTH, (N-1) * @RepayPeriodMths, @InitialPaymentDate) AS PaymentDate
    FROM NumberSequence
    WHERE DATEADD(MONTH, (N-1) * @RepayPeriodMths, @InitialPaymentDate) <= @ExpiryDate
),

-- Calculate working day payment dates
WorkingDayPayments AS (
    SELECT 
        r.N,
        COALESCE(
            (SELECT TOP 1 c.AsAtDate
             FROM [dbo].[syn_Model_tbl_Dim_Calendar] c
             WHERE c.RegionCode = 'UK' 
               AND c.IsWorkingDay = 1 
               AND c.[Month] = MONTH(r.PaymentDate)
               AND c.[Year] = YEAR(r.PaymentDate)
               AND c.AsAtDate <= @ExpiryDate
             ORDER BY c.AsAtDate DESC),
            @ExpiryDate
        ) AS PaymentDate
    FROM RepaymentDates r
),

-- Calculate interest applications and repayments
Calculations AS (
    SELECT 
        N,
        PaymentDate,
        CASE 
            WHEN @InterestAppliedToCode = '1' AND (N-1) % 3 = 0
            THEN @BalanceAmt * @EffIntRate * 90 / 36500
            ELSE 0
        END AS InterestAmount,
        @RepaymentAmt AS RepaymentAmount,
        @BalanceAmt + (@RepaymentAmt * N) AS RunningBalance
    FROM WorkingDayPayments
)

-- Final result set
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
SELECT 
    @FacilityId,
    CASE
        WHEN PaymentDate = @ExpiryDate THEN ABS(RunningBalance) + InterestAmount
        WHEN RunningBalance >= 0 THEN 0
        ELSE RepaymentAmount + InterestAmount
    END AS RepaymentAmount,
    CASE
        WHEN RunningBalance >= 0 OR PaymentDate = @ExpiryDate THEN 0
        ELSE CASE 
            WHEN ABS(RunningBalance) < RepaymentAmount THEN ABS(RunningBalance)
            ELSE RepaymentAmount
        END
    END AS PrincipalAmount,
    PaymentDate
FROM Calculations
WHERE RunningBalance < 0 OR PaymentDate = @ExpiryDate
ORDER BY N;

-- Update final balance (if needed for further processing)
SET @BalanceAmt = (SELECT TOP 1 RunningBalance FROM Calculations ORDER BY N DESC);
