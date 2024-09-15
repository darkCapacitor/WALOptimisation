using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Linq;
using Microsoft.Data.SqlClient;

public class RepaymentScheduleCalculator
{
    private readonly string _connectionString;

    public RepaymentScheduleCalculator(string connectionString)
    {
        _connectionString = connectionString;
    }

    public void CalculateRepaymentSchedules()
    {
        var tmpData = FetchTmpDataCAU();
        var calendar = FetchCalendarData();

        var repaymentSchedules = new List<RepaymentSchedule>();

        foreach (var data in tmpData.OrderByDescending(d => d.Seq))
        {
            var balanceAmt = data.UtilisationGbpReportingDate;
            var firstPaymentDate = data.NextLmtReductionDate;
            var expiryDate = GetLastWorkingDay(data.ExpiryDate, calendar);
            var nextPaymentDate = GetLastWorkingDay(DateTime.ParseExact(firstPaymentDate, "yyMMdd", null), calendar);
            var nextInterestSequence = CalculateNextInterestSequence(data.LatestMonthEnd, data.UpcomingQtr);

            if (nextPaymentDate > data.FirstPaymentScheduleDate)
            {
                repaymentSchedules.Add(new RepaymentSchedule
                {
                    FacilityId = data.FacilityId,
                    RepaymentAmount = 0,
                    PrincipalAmount = Math.Abs(balanceAmt),
                    PaymentDate = data.FirstPaymentScheduleDate
                });
            }
            else
            {
                nextPaymentDate = data.FirstPaymentScheduleDate;
            }

            var sequence = 0;
            var currentSequence = 0;
            var isFirstPayment = true;
            var repaymentInterest = 0.0m;

            while (balanceAmt < 0)
            {
                decimal interestAmt = 0;
                if (data.InterestAppliedToCode == "1" && nextInterestSequence == currentSequence)
                {
                    interestAmt = balanceAmt * data.EffIntRate * 90 / 36500;
                    balanceAmt += interestAmt;
                    nextInterestSequence += 3;
                    repaymentInterest += interestAmt;
                }

                if (data.InterestAppliedToCode != "1" || sequence == currentSequence)
                {
                    var nextPayment = isFirstPayment ? nextPaymentDate : nextPaymentDate.AddMonths(data.RepayPeriodMths);
                    nextPaymentDate = GetLastWorkingDay(nextPayment, calendar);

                    if (expiryDate > nextPaymentDate)
                    {
                        balanceAmt += data.RepaymentAmt;
                    }

                    decimal nextRepaymentAmt;
                    if (expiryDate <= nextPaymentDate)
                    {
                        nextRepaymentAmt = Math.Abs(balanceAmt) + repaymentInterest;
                    }
                    else if (balanceAmt + data.RepaymentAmt < data.RepaymentAmt)
                    {
                        nextRepaymentAmt = data.RepaymentAmt + repaymentInterest;
                    }
                    else
                    {
                        nextRepaymentAmt = Math.Abs(balanceAmt) + repaymentInterest;
                    }

                    repaymentSchedules.Add(new RepaymentSchedule
                    {
                        FacilityId = data.FacilityId,
                        RepaymentAmount = nextRepaymentAmt,
                        PrincipalAmount = balanceAmt > 0 || expiryDate <= nextPaymentDate ? 0 : Math.Abs(balanceAmt),
                        PaymentDate = nextPaymentDate
                    });

                    isFirstPayment = false;
                    if (expiryDate <= nextPaymentDate)
                    {
                        balanceAmt = 0;
                    }
                    sequence += data.RepayPeriodMths;
                    repaymentInterest = 0;
                }
                currentSequence++;
            }
        }

        BulkInsertRepaymentSchedules(repaymentSchedules);
    }

    private List<TmpDataCAU> FetchTmpDataCAU()
    {
        // Implementation to fetch data from #tmpDataCAU
    }

    private List<CalendarData> FetchCalendarData()
    {
        // Implementation to fetch data from [dbo].[syn_Model_tbl_Dim_Calendar]
    }

    private DateTime GetLastWorkingDay(DateTime date, List<CalendarData> calendar)
    {
        // Implementation to get the last working day
    }

    private int CalculateNextInterestSequence(DateTime latestMonthEnd, DateTime upcomingQtr)
    {
        // Implementation to calculate next interest sequence
    }

    private void BulkInsertRepaymentSchedules(List<RepaymentSchedule> repaymentSchedules)
    {
        using (var connection = new SqlConnection(_connectionString))
        {
            connection.Open();
            using (var bulkCopy = new SqlBulkCopy(connection))
            {
                bulkCopy.DestinationTableName = "DW.CAU_RepaymentsSchedules_TEMP";
                bulkCopy.WriteToServer(ConvertToDataTable(repaymentSchedules));
            }
        }
    }

    private DataTable ConvertToDataTable(List<RepaymentSchedule> repaymentSchedules)
    {
        // Implementation to convert List<RepaymentSchedule> to DataTable
    }
}

public class TmpDataCAU
{
    // Properties matching #tmpDataCAU columns
}

public class CalendarData
{
    // Properties matching [dbo].[syn_Model_tbl_Dim_Calendar] columns
}

public class RepaymentSchedule
{
    public int FacilityId { get; set; }
    public decimal RepaymentAmount { get; set; }
    public decimal PrincipalAmount { get; set; }
    public DateTime PaymentDate { get; set; }
}
