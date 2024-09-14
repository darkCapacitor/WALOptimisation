WITH NumberSequence AS (
    SELECT TOP (1000) -- Adjust based on your maximum expected iterations
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
    FROM master.dbo.spt_values t1
    CROSS JOIN master.dbo.spt_values t2
),

-- Generate repayment schedule
RepaymentSchedule AS (
    SELECT 
        N,
        CASE 
            WHEN N = 1 THEN @NextPaymentDate
            ELSE DATEADD(MONTH, (N-1) * @RepayPeriodMths, @NextPaymentDate)
        END AS ScheduledDate
    FROM NumberSequence
),

-- Adjust for working days and apply interest
Calculations AS (
    SELECT 
        r.N,
        COALESCE(
            (SELECT TOP 1 c.AsAtDate
             FROM [dbo].[syn_Model_tbl_Dim_Calendar] c
             WHERE c.RegionCode = 'UK' 
               AND c.IsWorkingDay = 1 
               AND c.[Month] = MONTH(r.ScheduledDate)
               AND c.[Year] = YEAR(r.ScheduledDate)
               AND c.AsAtDate <= @ExpiryDate
             ORDER BY c.AsAtDate DESC),
            @ExpiryDate
        ) AS PaymentDate,
        CASE 
            WHEN @InterestAppliedToCode = '1' AND ((r.N - 1) % 3 = 0)
            THEN @BalanceAmt * @EffIntRate * 90 / 36500
            ELSE 0
        END AS InterestAmount,
        @RepaymentAmt AS RepaymentAmount,
        @BalanceAmt + (@RepaymentAmt * r.N) AS RunningBalance
    FROM RepaymentSchedule r
)

-- Final result set
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
SELECT 
    @FacilityId,
    CASE
        WHEN PaymentDate = @ExpiryDate THEN ABS(RunningBalance) + InterestAmount
        WHEN RunningBalance >= 0 THEN 0
        ELSE 
            CASE
                WHEN ABS(RunningBalance) < RepaymentAmount THEN ABS(RunningBalance) + InterestAmount
                ELSE RepaymentAmount + InterestAmount
            END
    END AS RepaymentAmount,
    CASE
        WHEN RunningBalance >= 0 OR PaymentDate = @ExpiryDate THEN 0
        ELSE 
            CASE
                WHEN ABS(RunningBalance) < RepaymentAmount THEN ABS(RunningBalance)
                ELSE RepaymentAmount
            END
    END AS PrincipalAmount,
    PaymentDate
FROM Calculations
WHERE RunningBalance < 0 OR PaymentDate = @ExpiryDate
ORDER BY N;
