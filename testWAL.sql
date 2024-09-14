-- Create a numbers table for generating sequences
WITH NumberSequence AS (
    SELECT TOP (10000) -- Adjust this number based on your maximum expected iterations
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

-- Calculate interest applications
InterestCalculations AS (
    SELECT 
        N,
        PaymentDate,
        CASE 
            WHEN @InterestAppliedToCode = '1' AND (N-1) % 3 = 0
            THEN @BalanceAmt * @EffIntRate * 90 / 36500
            ELSE 0
        END AS InterestAmount
    FROM WorkingDayPayments
),

-- Calculate cumulative repayments and balances
Repayments AS (
    SELECT 
        N,
        PaymentDate,
        InterestAmount,
        @RepaymentAmt AS RepaymentAmount,
        SUM(InterestAmount) OVER (ORDER BY N) AS CumulativeInterest,
        SUM(@RepaymentAmt) OVER (ORDER BY N) AS CumulativeRepayment,
        @BalanceAmt + SUM(@RepaymentAmt) OVER (ORDER BY N) AS RunningBalance
    FROM InterestCalculations
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
        ELSE LEAST(ABS(RunningBalance), RepaymentAmount)
    END AS PrincipalAmount,
    PaymentDate
FROM Repayments
WHERE RunningBalance < 0 OR PaymentDate = @ExpiryDate
ORDER BY N;

-- Update final balance (if needed for further processing)
UPDATE @BalanceAmt = (SELECT TOP 1 RunningBalance FROM Repayments ORDER BY N DESC);
